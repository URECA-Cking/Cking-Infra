import datetime
import json

import pytest

import actions
import tools

UTC = datetime.timezone.utc


def at(minute):
    return datetime.datetime(2026, 11, 5, 0, minute, tzinfo=UTC)


def activity(minute, status="Successful", description="Launching a new EC2 instance: i-1", message=None, cause="c"):
    item = {"StartTime": at(minute), "StatusCode": status, "Description": description, "Cause": cause}
    if message:
        item["StatusMessage"] = message
    return item


def paginate(client, operation, pages):
    paginator = client.get_paginator.return_value
    paginator.paginate.return_value = pages
    return paginator


class TestJson:
    def test_datetime_in_utc(self):
        kst = datetime.timezone(datetime.timedelta(hours=9))
        assert tools._json({"t": datetime.datetime(2026, 11, 5, 9, 0, tzinfo=kst)}) == '{"t": "2026-11-05T00:00:00Z"}'

    def test_truncated(self):
        text = tools._json("가" * 20000)
        assert len(text) == tools.MAX_RESULT_CHARS + len("…(잘림)")
        assert text.endswith("…(잘림)")


class TestInputValidation:
    @pytest.mark.parametrize("name", ["../secret", "a.md", "runbook name", ""])
    def test_runbook_name(self, name):
        assert tools.read_runbook.func(name) == "이름은 영문·숫자·하이픈만 쓴다"

    def test_runbook_read_failure_reported(self):
        assert tools.read_runbook.func("README").startswith("런북을 읽지 못했다: ")

    @pytest.mark.parametrize("name", ["other-app", "dev-cking-", "prod-cking-App", "staging-cking-app", "dev-cking-app;x"])
    def test_cking_names_only(self, name):
        assert tools.describe_scaling_activities.func(name) == "크킹 서버 그룹 이름만 조회한다"
        assert tools.describe_instances.func(name) == "크킹 이름표나 서버 ID로만 조회한다"
        assert tools.describe_target_health.func(name) == "크킹 대상 그룹 이름만 조회한다"
        tools._autoscaling.get_paginator.assert_not_called()
        tools._ec2.describe_instances.assert_not_called()

    @pytest.mark.parametrize("instance", ["i-1", "i-0123456789ABCDEF0", "0123456789abcdef0"])
    def test_instance_id_format(self, instance):
        assert tools.get_console_output.func(instance) == "서버 ID 형식이 아니다"
        assert tools.list_server_operations.func(instance, "2026-11-05T00:00:00Z") == "서버 ID 형식이 아니다"

    def test_release_tags_env(self):
        assert tools.list_release_tags.func("loadtest") == "env는 dev나 prod다"


class TestScalingActivities:
    def test_recent_15_without_since(self):
        paginate(tools._autoscaling, "describe_scaling_activities",
                 [{"Activities": [activity(59 - i) for i in range(10)]}, {"Activities": [activity(49 - i) for i in range(10)]}])
        rows = json.loads(tools.describe_scaling_activities.func("prod-cking-app"))
        assert len(rows) == 15
        assert rows[0]["start"] == "2026-11-05T00:59:00Z"

    def test_range_groups_repeated_failures(self):
        failed = dict(status="Failed", message="We currently do not have sufficient capacity")
        paginate(tools._autoscaling, "describe_scaling_activities", [{"Activities": [
            activity(50),
            activity(40, **failed), activity(30, **failed), activity(20, **failed),
            activity(15, description="Terminating EC2 instance: i-2", cause="spot"),
            activity(5),
        ]}])
        body = json.loads(tools.describe_scaling_activities.func("dev-cking-recommendation", since="2026-11-05T00:10:00Z",
                                                                  until="2026-11-05T00:45:00Z"))
        assert body["total"] == 4
        assert body["counts"] == {"Launching Failed": 3, "Terminating Successful": 1}
        assert body["failure_reasons"] == {"We currently do not have sufficient capacity": 3}
        terminating, failures = body["activities"]
        assert terminating["cause"] == "spot"
        assert failures["start"] == "2026-11-05T00:20:00Z"
        assert failures["repeated"] == 3
        assert failures["last_start"] == "2026-11-05T00:40:00Z"

    def test_stops_paging_before_since(self):
        paginator = paginate(tools._autoscaling, "describe_scaling_activities", iter([
            {"Activities": [activity(30), activity(1)]}, {"Activities": [activity(0)]}]))
        body = json.loads(tools.describe_scaling_activities.func("dev-cking-app", since="2026-11-05T00:10:00Z"))
        assert body["total"] == 1
        assert paginator.paginate.call_count == 1

    def test_terminating_only(self):
        paginate(tools._autoscaling, "describe_scaling_activities", [{"Activities": [
            activity(30), activity(20, description="Terminating EC2 instance: i-2")]}])
        rows = json.loads(tools.describe_scaling_activities.func("dev-cking-app", terminating_only=True))
        assert [r["description"][:11] for r in rows] == ["Terminating"]


def test_console_output_error_lines():
    lines = [f"line {i}" for i in range(50)] + ["Traceback (most recent call last):", "ok"]
    tools._ec2.get_console_output.return_value = {"Output": "\n".join(lines)}
    body = json.loads(tools.get_console_output.func("i-0123456789abcdef0"))
    assert body["error_lines"] == ["Traceback (most recent call last):"]
    assert len(body["last_lines"]) == 40


def test_cloudwatch_metric_bounds():
    tools._cloudwatch.get_metric_statistics.return_value = {"Datapoints": [
        {"Timestamp": at(2), "Maximum": 2.0}, {"Timestamp": at(1), "Maximum": 1.0}]}
    body = json.loads(tools.get_cloudwatch_metric.func("AWS/RDS", "CPUUtilization", {"DBInstanceIdentifier": "prod-cking-mysql"},
                                                       statistic="Maximum", minutes=99999, period=90, end="2026-11-05T01:00:00Z"))
    assert body == [["2026-11-05T00:01:00Z", 1.0], ["2026-11-05T00:02:00Z", 2.0]]
    sent = tools._cloudwatch.get_metric_statistics.call_args.kwargs
    assert sent["Period"] == 60
    assert sent["EndTime"] - sent["StartTime"] == datetime.timedelta(minutes=1440)
    assert sent["Dimensions"] == [{"Name": "DBInstanceIdentifier", "Value": "prod-cking-mysql"}]


def test_release_tags_prod_current():
    paginate(tools._s3, "list_objects_v2", [{"CommonPrefixes": [{"Prefix": f"releases/2026110{i}000000-abcdef{i}/"} for i in range(1, 4)]}])
    tools._ssm.get_parameter.return_value = {"Parameter": {"Value": "20261103000000-abcdef3"}}
    body = json.loads(tools.list_release_tags.func("prod"))
    assert body["tags"][0] == "20261103000000-abcdef3"
    assert body["current"] == "20261103000000-abcdef3"


class TestProposeAction:
    def test_records_passing_proposal(self, monkeypatch):
        seen = []
        monkeypatch.setattr(actions, "check", lambda action, params: (seen.append(params) or (True, "영향")))
        reply = tools.propose_action.func("comment_filter", env="dev", blocked=False)
        assert reply == "제안을 기록했다. 버튼이 붙는다. 영향: 영향"
        assert seen == [{"env": "dev", "blocked": False}]
        assert tools.PROPOSAL == {"action": "comment_filter", "params": {"env": "dev", "blocked": False}, "ok": True,
                                  "note": "영향", "title": "댓글 필터 차단·해제(개발 해제)"}

    def test_records_refused_proposal(self, monkeypatch):
        monkeypatch.setattr(actions, "check", lambda action, params: (False, "정상 서버가 1대"))
        reply = tools.propose_action.func("app_capacity_set", desired_capacity=3)
        assert reply.startswith("실행 직전 검사를 통과하지 못해 버튼이 붙지 않는다: 정상 서버가 1대")
        assert tools.PROPOSAL["ok"] is False
        assert tools.PROPOSAL["params"] == {"desired_capacity": 3, "blocked": True}

    def test_last_proposal_wins(self, monkeypatch):
        monkeypatch.setattr(actions, "check", lambda action, params: (True, "x"))
        tools.propose_action.func("dev_app_restart")
        tools.propose_action.func("prod_redis_scale_up")
        assert tools.PROPOSAL["action"] == "prod_redis_scale_up"

    def test_schema_lists_every_action(self):
        schema = tools.propose_action.input_schema
        assert set(schema["properties"]["action"]["enum"]) == set(actions.ACTIONS)
