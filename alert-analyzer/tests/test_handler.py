import json

import pytest

import handler

RUNBOOK = "https://github.com/URECA-Cking/Cking-Infra/blob/main/docs/runbooks/cking-stream-lag.md"


def sns(message):
    return {"Sns": {"Message": message if isinstance(message, str) else json.dumps(message)}}


def grafana(env="dev", alerts=None):
    return {"source": "grafana", "alerts": alerts if alerts is not None else [
        {"labels": {"alertname": "StreamLag", "env": env}, "annotations": {"runbook_url": RUNBOOK, "summary": "lag"},
         "fingerprint": "fp1", "startsAt": "2026-11-05T00:00:00Z", "valueString": "B=20000"},
        {"labels": {"alertname": "StreamLag", "env": env}, "annotations": {}, "fingerprint": "fp2", "startsAt": "2026-11-05T00:01:00Z"},
    ]}


def cloudwatch(name="prod-cking-alb-5xx", state="ALARM"):
    return {"AlarmName": name, "NewStateValue": state, "AlarmDescription": f"런북 {RUNBOOK}",
            "StateChangeTime": "2026-11-05T00:00:00.000+0000", "NewStateReason": "Threshold Crossed"}


def result(text="*판단*: 지금 조치 필요 이유", proposal=None):
    return {"text": text, "usage": {"tool_calls": 3, "cost": 0.123}, "proposal": proposal, "ok": True}


PROPOSAL = {"action": "dev_app_restart", "params": {}, "ok": True, "note": "개발 API가 멈춘다", "title": "개발 앱 컨테이너 재시작"}


class TestParse:
    def test_grafana(self):
        alert = handler.parse(grafana())
        assert alert["name"] == "StreamLag"
        assert alert["env"] == "dev"
        assert alert["keys"] == ["grafana#fp1#2026-11-05T00:00:00Z", "grafana#fp2#2026-11-05T00:01:00Z"]
        assert alert["runbook_link"] == f"<{RUNBOOK}|cking-stream-lag>"
        assert "Grafana 경보가 울렸다. 환경: 개발. 런북 파일: cking-stream-lag." in alert["prompt"]
        assert "B=20000" in alert["prompt"]

    def test_grafana_prod_label(self):
        assert handler.parse(grafana(env="prod"))["env"] == "prod"

    def test_grafana_without_alerts(self):
        assert handler.parse(grafana(alerts=[])) is None

    def test_cloudwatch_alarm(self):
        alert = handler.parse(cloudwatch())
        assert alert["env"] == "prod"
        assert alert["keys"] == ["cloudwatch#prod-cking-alb-5xx#2026-11-05T00:00:00.000+0000"]
        assert alert["runbook_link"].endswith("|cking-stream-lag>")

    def test_cloudwatch_dev_by_name(self):
        assert handler.parse(cloudwatch(name="dev-cking-app-cpu"))["env"] == "dev"

    @pytest.mark.parametrize("state", ["OK", "INSUFFICIENT_DATA"])
    def test_cloudwatch_recovery_ignored(self, state):
        assert handler.parse(cloudwatch(state=state)) is None

    def test_custom_event(self):
        alert = handler.parse({"source": "custom", "content": {"title": "GuardDuty 발견", "nextSteps": [RUNBOOK]}})
        assert alert["name"] == "GuardDuty 발견"
        assert alert["env"] == "prod"
        assert alert["keys"][0].startswith("event#GuardDuty 발견#")
        assert alert["runbook_link"].endswith("|cking-stream-lag>")

    @pytest.mark.parametrize("message", [{}, {"source": "custom"}, {"source": "other", "content": {"title": "x"}}])
    def test_unknown_format(self, message):
        assert handler.parse(message) is None

    def test_no_runbook_link(self):
        alert = handler.build("x", "dev", "https://example.com/runbook.md", ["k"], "CloudWatch 경보", {})
        assert alert["runbook_link"] == "런북 링크 없음"
        assert "런북 파일: 알 수 없음" in alert["prompt"]

    def test_details_truncated(self):
        alert = handler.build("x", "dev", "", ["k"], "CloudWatch 경보", {"big": "가" * 20000})
        assert len(alert["prompt"].split("경보 내용(데이터):\n", 1)[1]) == 8000


class TestClaim:
    def test_new_key(self):
        assert handler.claim(["a"])
        item = handler._dynamodb.put_item.call_args.kwargs
        assert item["ConditionExpression"] == "attribute_not_exists(#k)"
        assert item["Item"]["key"] == {"S": "a"}

    def test_all_seen(self, client_error):
        handler._dynamodb.put_item.side_effect = client_error()
        assert not handler.claim(["a", "b"])

    def test_any_new_key_claims(self, client_error):
        handler._dynamodb.put_item.side_effect = [client_error(), None]
        assert handler.claim(["a", "b"])

    def test_other_error_raises(self, client_error):
        handler._dynamodb.put_item.side_effect = client_error("AccessDeniedException")
        with pytest.raises(Exception):
            handler.claim(["a"])


class TestDailyLimit:
    def test_within(self, slack_calls):
        assert handler.within_daily_limit("dev")
        update = handler._dynamodb.update_item.call_args.kwargs
        assert update["Key"]["key"]["S"].startswith("day#dev#")
        assert update["ExpressionAttributeValues"][":limit"] == {"N": str(handler.DAILY_LIMIT)}
        assert slack_calls["post"] == []

    def test_over_limit_notifies_once(self, slack_calls, client_error):
        handler._dynamodb.update_item.side_effect = client_error()
        assert not handler.within_daily_limit("prod")
        assert "하루 상한" in slack_calls["post"][0]["text"]
        assert slack_calls["post"][0]["env"] == "prod"

        handler._dynamodb.put_item.side_effect = client_error()
        assert not handler.within_daily_limit("prod")
        assert len(slack_calls["post"]) == 1

    def test_other_error_raises(self, slack_calls, client_error):
        handler._dynamodb.update_item.side_effect = client_error("InternalServerError")
        with pytest.raises(Exception):
            handler.within_daily_limit("dev")


class TestHandler:
    @pytest.fixture
    def diagnosed(self, monkeypatch):
        prompts = []

        def fake(prompt):
            prompts.append(prompt)
            return result(text="*판단*: 조치 필요 없음 회복됨")

        monkeypatch.setattr(handler, "diagnose", fake)
        return prompts

    def test_not_json_skipped(self, diagnosed, slack_calls):
        handler.handler({"Records": [sns("not json"), {"Sns": {}}]}, None)
        assert diagnosed == []

    def test_diagnoses_and_posts(self, diagnosed, slack_calls):
        handler.handler({"Records": [sns(grafana())]}, None)
        assert len(diagnosed) == 1
        assert "*[AI 진단] StreamLag*" in slack_calls["post"][0]["text"]

    def test_already_claimed(self, diagnosed, slack_calls, client_error):
        handler._dynamodb.put_item.side_effect = client_error()
        handler.handler({"Records": [sns(grafana())]}, None)
        assert diagnosed == []
        assert slack_calls["post"] == []

    def test_over_daily_limit(self, diagnosed, slack_calls, monkeypatch):
        monkeypatch.setattr(handler, "within_daily_limit", lambda env: False)
        handler.handler({"Records": [sns(grafana())]}, None)
        assert diagnosed == []

    def test_diagnose_failure_posts_runbook(self, slack_calls, monkeypatch):
        def fail(prompt):
            raise ValueError("credit balance too low")

        monkeypatch.setattr(handler, "diagnose", fail)
        handler.handler({"Records": [sns(cloudwatch())]}, None)
        [post] = slack_calls["post"]
        assert post["env"] == "prod"
        assert post["text"].startswith("*[AI 진단 실패] prod-cking-alb-5xx* · 운영 환경")
        assert "`ValueError`" in post["text"]
        assert "credit balance" not in post["text"]
        assert "|cking-stream-lag>" in post["text"]

    def test_one_failure_does_not_stop_others(self, slack_calls, monkeypatch):
        calls = []

        def flaky(prompt):
            calls.append(prompt)
            if len(calls) == 1:
                raise RuntimeError("x")
            return result(text="*판단*: 조치 필요 없음")

        monkeypatch.setattr(handler, "diagnose", flaky)
        handler.handler({"Records": [sns(cloudwatch()), sns(grafana())]}, None)
        assert len(calls) == 2
        assert [p["text"].split("*")[1] for p in slack_calls["post"]] == ["[AI 진단 실패] prod-cking-alb-5xx", "[AI 진단] StreamLag"]


class TestPublish:
    def alert(self):
        return handler.parse(grafana())

    def test_render(self):
        text, blocks = handler.render(self.alert(), result(text="본문"))
        assert text.endswith("_런북: <" + RUNBOOK + "|cking-stream-lag> · 조회 3번 · $0.12_")
        assert blocks[-1]["type"] == "context"
        assert blocks[0]["text"]["text"].startswith("*[AI 진단] StreamLag* · 개발 환경\n본문")

    def test_without_proposal(self, slack_calls):
        handler.publish(self.alert(), result())
        assert len(slack_calls["post"]) == 1
        handler._dynamodb.put_item.assert_not_called()

    def test_proposal_ignored_unless_action_needed(self, slack_calls):
        handler.publish(self.alert(), result(text="*판단*: 사람 판단 필요 이유", proposal=PROPOSAL))
        handler._dynamodb.put_item.assert_not_called()
        assert not any(b["type"] == "actions" for b in slack_calls["post"][0]["blocks"])

    def test_refused_proposal_noted(self, slack_calls):
        refused = {**PROPOSAL, "ok": False, "note": "정상 서버가 1대라 교체하지 않는다"}
        handler.publish(self.alert(), result(proposal=refused))
        handler._dynamodb.put_item.assert_not_called()
        blocks = slack_calls["post"][0]["blocks"]
        assert blocks[-1]["elements"][0]["text"] == "조치 버튼 없음(개발 앱 컨테이너 재시작): 정상 서버가 1대라 교체하지 않는다"
        assert not any(b["type"] == "actions" for b in blocks)

    def test_button_attached_and_recorded(self, slack_calls):
        handler.publish(self.alert(), result(proposal=PROPOSAL))
        item = handler._dynamodb.put_item.call_args.kwargs["Item"]
        record_id = item["key"]["S"].removeprefix("action#")
        assert item["status"] == {"S": "pending"}
        assert item["action"] == {"S": "dev_app_restart"}
        assert int(item["valid_until"]["N"]) - int(item["expires_at"]["N"]) == handler.ACTION_VALID_SECONDS - 7 * 86400
        base = json.loads(item["base_blocks"]["S"])
        assert not any(b["type"] == "actions" for b in base)

        blocks = slack_calls["post"][0]["blocks"]
        assert [b["type"] for b in blocks[-3:]] == ["actions", "context", "context"]
        assert blocks[-3]["elements"][0]["value"] == record_id
        assert blocks[-1] == base[-1]

        saved = handler._dynamodb.update_item.call_args.kwargs
        assert saved["Key"] == {"key": {"S": f"action#{record_id}"}}
        assert saved["ExpressionAttributeValues"] == {":c": {"S": "C-DEV"}, ":t": {"S": "111.222"}}

    def test_webhook_fallback_skips_channel_record(self, slack_calls):
        slack_calls["post_return"] = (None, None)
        handler.publish(self.alert(), result(proposal=PROPOSAL))
        handler._dynamodb.put_item.assert_called_once()
        handler._dynamodb.update_item.assert_not_called()

    def test_button_limits(self):
        block = handler.button("r", "가" * 100, "나" * 500)
        element = block["elements"][0]
        assert len(element["text"]["text"]) == 75
        assert len(element["confirm"]["text"]["text"]) == 300
        assert element["action_id"] == "approve_action"
