import base64
import hashlib
import hmac
import json
import time
import urllib.parse

import pytest

import approvals
import slack

SECRET = "test-signing-secret"


@pytest.fixture(autouse=True)
def parameters(monkeypatch):
    values = {approvals.SIGNING_SECRET_PARAMETER: SECRET, approvals.APPROVERS_PARAMETER: "U-OK,U-OK2"}
    monkeypatch.setattr(slack, "_parameter", lambda name: values[name])


@pytest.fixture
def ephemeral(monkeypatch):
    sent = []
    monkeypatch.setattr(approvals, "_ephemeral", lambda url, text: sent.append(text))
    return sent


def signed(body, timestamp=None, secret=SECRET):
    timestamp = str(int(time.time()) if timestamp is None else timestamp)
    signature = "v0=" + hmac.new(secret.encode(), f"v0:{timestamp}:{body}".encode(), hashlib.sha256).hexdigest()
    return {"X-Slack-Request-Timestamp": timestamp, "X-Slack-Signature": signature}


def click_event(user="U-OK", record="abc123", kind="block_actions", action_id="approve_action", b64=False):
    payload = {"type": kind, "user": {"id": user}, "response_url": "https://hooks.slack.com/actions/x",
               "actions": [{"action_id": action_id, "value": record}]}
    body = urllib.parse.urlencode({"payload": json.dumps(payload)})
    headers = signed(body)
    if b64:
        body = base64.b64encode(body.encode()).decode()
    return {"body": body, "headers": headers, "isBase64Encoded": b64}


def approved_item(**extra):
    item = {"title": {"S": "개발 앱 컨테이너 재시작"}, "channel": {"S": "C-DEV"}, "ts": {"S": "1.2"},
            "base_blocks": {"S": json.dumps([{"type": "section"}, {"type": "context"}])}}
    item.update(extra)
    return {"Attributes": item}


class TestVerified:
    def test_valid_signature(self):
        headers = {k.lower(): v for k, v in signed("a=1").items()}
        assert approvals._verified(headers, "a=1")

    def test_wrong_secret(self):
        headers = {k.lower(): v for k, v in signed("a=1", secret="other").items()}
        assert not approvals._verified(headers, "a=1")

    def test_body_tampered(self):
        headers = {k.lower(): v for k, v in signed("a=1").items()}
        assert not approvals._verified(headers, "a=2")

    @pytest.mark.parametrize("offset", [-301, 301])
    def test_timestamp_outside_window(self, offset):
        headers = {k.lower(): v for k, v in signed("a=1", int(time.time()) + offset).items()}
        assert not approvals._verified(headers, "a=1")

    @pytest.mark.parametrize("timestamp", ["", "abc", "-1", "1.5", "²"])
    def test_timestamp_not_digits(self, timestamp):
        assert not approvals._verified({"x-slack-request-timestamp": timestamp, "x-slack-signature": "v0=x"}, "a=1")

    def test_non_ascii_signature(self):
        headers = {"x-slack-request-timestamp": str(int(time.time())), "x-slack-signature": "v0=é"}
        assert not approvals._verified(headers, "a=1")

    def test_missing_signature(self):
        assert not approvals._verified({"x-slack-request-timestamp": str(int(time.time()))}, "a=1")


class TestHandler:
    @pytest.mark.parametrize("signature", ["v0=bad", "v0=é"])
    def test_unsigned_request_rejected(self, ephemeral, signature):
        event = click_event()
        event["headers"]["X-Slack-Signature"] = signature
        assert approvals.handler(event, None)["statusCode"] == 401
        approvals._dynamodb.update_item.assert_not_called()
        approvals._lambda.invoke.assert_not_called()

    def test_other_interaction_ignored(self, ephemeral):
        assert approvals.handler(click_event(kind="view_submission"), None)["statusCode"] == 200
        assert approvals.handler(click_event(action_id="other"), None)["statusCode"] == 200
        approvals._dynamodb.update_item.assert_not_called()

    def test_non_approver_refused(self, ephemeral):
        assert approvals.handler(click_event(user="U-STRANGER"), None)["statusCode"] == 200
        assert "승인자 목록에 없어" in ephemeral[0]
        approvals._dynamodb.update_item.assert_not_called()
        approvals._lambda.invoke.assert_not_called()

    def test_approve_invokes_executor_and_marks_message(self, ephemeral, slack_calls):
        approvals._dynamodb.update_item.return_value = approved_item()
        assert approvals.handler(click_event(record="r1", b64=True), None)["statusCode"] == 200

        update = approvals._dynamodb.update_item.call_args.kwargs
        assert update["Key"] == {"key": {"S": "action#r1"}}
        assert update["ConditionExpression"] == "#s = :pending AND valid_until > :now"
        assert update["ExpressionAttributeValues"][":user"] == {"S": "U-OK"}
        invoke = approvals._lambda.invoke.call_args.kwargs
        assert invoke["FunctionName"] == "test-executor"
        assert invoke["InvocationType"] == "Event"
        assert json.loads(invoke["Payload"]) == {"id": "r1"}
        [marked] = slack_calls["update"]
        assert (marked["channel"], marked["ts"]) == ("C-DEV", "1.2")
        assert "승인: <@U-OK>" in marked["blocks"][1]["elements"][0]["text"]
        assert marked["blocks"][-1] == {"type": "context"}
        assert ephemeral == []

    def test_expired_request(self, ephemeral, client_error):
        approvals._dynamodb.update_item.side_effect = client_error()
        approvals._dynamodb.get_item.return_value = {"Item": {"status": {"S": "pending"}}}
        approvals.handler(click_event(), None)
        assert "15분이 지나" in ephemeral[0]
        approvals._lambda.invoke.assert_not_called()

    @pytest.mark.parametrize("status,expected", [("approved", "approved"), ("done", "done"), (None, "없음")])
    def test_already_handled(self, ephemeral, client_error, status, expected):
        approvals._dynamodb.update_item.side_effect = client_error()
        approvals._dynamodb.get_item.return_value = {"Item": {"status": {"S": status}}} if status else {}
        approvals.handler(click_event(), None)
        assert ephemeral == [f"이미 처리된 조치다({expected})."]
        approvals._lambda.invoke.assert_not_called()

    def test_other_dynamodb_error_raises(self, ephemeral, client_error):
        approvals._dynamodb.update_item.side_effect = client_error("ProvisionedThroughputExceededException")
        with pytest.raises(Exception):
            approvals.handler(click_event(), None)
        approvals._lambda.invoke.assert_not_called()

    def test_message_update_failure_is_not_fatal(self, ephemeral, monkeypatch):
        approvals._dynamodb.update_item.return_value = approved_item()

        def fail(*args):
            raise RuntimeError("slack down")

        monkeypatch.setattr(slack, "update", fail)
        assert approvals.handler(click_event(), None)["statusCode"] == 200
        approvals._lambda.invoke.assert_called_once()


class TestEphemeral:
    @pytest.mark.parametrize("url", ["", "https://example.com/x", "http://hooks.slack.com/x", "https://hooks.slack.com.evil.example/x"])
    def test_only_slack_response_url(self, url):
        approvals._ephemeral(url, "text")

    def test_slack_response_url_posts_ephemeral(self, monkeypatch):
        sent = []

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self):
                return b"ok"

        def urlopen(request, timeout):
            sent.append(json.loads(request.data))
            return Response()

        monkeypatch.setattr(approvals.urllib.request, "urlopen", urlopen)
        approvals._ephemeral("https://hooks.slack.com/actions/x", "안내")
        assert sent == [{"response_type": "ephemeral", "replace_original": False, "text": "안내"}]
