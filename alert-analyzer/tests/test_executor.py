import json

import pytest

import actions
import executor
import slack

BASE = [{"type": "section"}, {"type": "context", "elements": [{"type": "mrkdwn", "text": "런북"}]}]


def running_item(**extra):
    item = {"action": {"S": "dev_app_restart"}, "title": {"S": "개발 앱 컨테이너 재시작"}, "env": {"S": "dev"},
            "approver": {"S": "U-OK"}, "params": {"S": "{}"}, "base_blocks": {"S": json.dumps(BASE)},
            "channel": {"S": "C-DEV"}, "ts": {"S": "1.2"}}
    item.update(extra)
    return {"Attributes": item}


@pytest.fixture
def run_action(monkeypatch):
    calls = []
    outcome = {"value": (True, "Success\n```ok```")}

    def run(action, params):
        calls.append((action, params))
        if isinstance(outcome["value"], Exception):
            raise outcome["value"]
        return outcome["value"]

    monkeypatch.setattr(actions, "run", run)
    return calls, outcome


def saved(index=-1):
    return executor._dynamodb.update_item.call_args_list[index].kwargs


def test_not_approved_is_skipped(run_action, slack_calls, client_error):
    executor._dynamodb.update_item.side_effect = client_error()
    executor.handler({"id": "r1"}, None)
    assert run_action[0] == []
    assert slack_calls["post"] == []


def test_other_error_raises(run_action, slack_calls, client_error):
    executor._dynamodb.update_item.side_effect = client_error("ThrottlingException")
    with pytest.raises(Exception):
        executor.handler({"id": "r1"}, None)
    assert run_action[0] == []


def test_success(run_action, slack_calls):
    executor._dynamodb.update_item.side_effect = [running_item(params={"S": '{"env": "dev"}'}), None]
    executor.handler({"id": "r1"}, None)

    claim = saved(0)
    assert claim["Key"] == {"key": {"S": "action#r1"}}
    assert claim["ConditionExpression"] == "#s = :approved"
    assert run_action[0] == [("dev_app_restart", {"env": "dev"})]
    final = saved(1)
    assert final["ExpressionAttributeValues"][":status"] == {"S": "done"}
    assert final["UpdateExpression"] == "SET #status = :status, #result = :result, #finished_at = :finished_at"

    [post] = slack_calls["post"]
    assert post["thread_ts"] == "1.2"
    assert post["text"].startswith("*[AI 조치] 개발 앱 컨테이너 재시작* · 개발 환경 · 실행함\n승인: <@U-OK>")
    [marked] = slack_calls["update"]
    assert marked["text"] == "[AI 조치] 개발 앱 컨테이너 재시작 실행함"
    assert marked["blocks"][0] == BASE[0] and marked["blocks"][-1] == BASE[-1]
    assert "결과는 스레드" in marked["blocks"][1]["elements"][0]["text"]


def test_refused_marks_failed(run_action, slack_calls):
    run_action[1]["value"] = (False, "실행하지 않았다: 정상 서버가 1대")
    executor._dynamodb.update_item.side_effect = [running_item(), None]
    executor.handler({"id": "r1"}, None)
    assert saved(1)["ExpressionAttributeValues"][":status"] == {"S": "failed"}
    assert "실행하지 못함" in slack_calls["post"][0]["text"]


def test_exception_is_recorded(run_action, slack_calls):
    run_action[1]["value"] = ValueError("x" * 1000)
    executor._dynamodb.update_item.side_effect = [running_item(), None]
    executor.handler({"id": "r1"}, None)
    result = saved(1)["ExpressionAttributeValues"][":result"]["S"]
    assert result.startswith("실패: `ValueError` ")
    assert len(result) == len("실패: `ValueError` ") + 500
    assert saved(1)["ExpressionAttributeValues"][":status"] == {"S": "failed"}


def test_long_result_cut_in_table(run_action, slack_calls):
    run_action[1]["value"] = (True, "r" * 5000)
    executor._dynamodb.update_item.side_effect = [running_item(), None]
    executor.handler({"id": "r1"}, None)
    assert len(saved(1)["ExpressionAttributeValues"][":result"]["S"]) == 3000


def test_webhook_message_without_channel(run_action, slack_calls):
    item = running_item()
    del item["Attributes"]["channel"], item["Attributes"]["ts"]
    executor._dynamodb.update_item.side_effect = [item, None]
    executor.handler({"id": "r1"}, None)
    assert slack_calls["post"][0]["thread_ts"] is None
    assert slack_calls["update"] == []


def test_message_update_failure_is_not_fatal(run_action, slack_calls, monkeypatch):
    def fail(*args):
        raise RuntimeError("slack")

    monkeypatch.setattr(slack, "update", fail)
    executor._dynamodb.update_item.side_effect = [running_item(), None]
    executor.handler({"id": "r1"}, None)
    assert len(slack_calls["post"]) == 1
