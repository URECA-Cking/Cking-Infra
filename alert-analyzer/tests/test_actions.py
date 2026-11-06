import json

import pytest

import actions


@pytest.fixture
def documents(monkeypatch):
    calls = []

    def run(instance, document, parameters, timeout):
        calls.append((instance, document, parameters, timeout))
        return "Success", "line\n" * 30

    monkeypatch.setattr(actions, "run_document", run)
    return calls


@pytest.fixture
def github(monkeypatch):
    calls = []
    running = set()

    def call(method, url, payload=None):
        calls.append((method, url, payload))
        return {"total_count": 1 if any(r in url for r in running) else 0}

    monkeypatch.setattr(actions, "_github", call)
    return calls, running


def check(action, **params):
    return actions.check(action, params)


def run(action, **params):
    return actions.run(action, params)


class TestHelpers:
    @pytest.mark.parametrize("number,expected", [(0, "0으로"), (2, "2로"), (3, "3으로"), (6, "6으로"), (7, "7로"), (8, "8로"), (10, "10으로"), (13, "13으로")])
    def test_particle(self, number, expected):
        assert actions._to(number) == expected

    def test_tail(self):
        assert actions._tail("\n".join(str(i) for i in range(20)) + "\n", 3) == "17\n18\n19"
        assert actions._tail(None) == ""

    @pytest.mark.parametrize("env", [None, "", "staging", "PROD"])
    def test_env_refused(self, env):
        with pytest.raises(actions.Refused):
            actions._env({"env": env})

    def test_unknown_action(self):
        assert actions.check("rm_rf", {}) == (False, "목록에 없는 조치다")

    @pytest.mark.parametrize("action,params,expected", [
        ("dev_app_restart", {}, "개발 앱 컨테이너 재시작"),
        ("batch_server_replace", {"env": "prod"}, "추천 배치 서버 교체(운영)"),
        ("app_server_replace", {"instance_id": "i-0123456789abcdef0"}, "운영 앱 서버 1대 교체(i-0123456789abcdef0)"),
        ("app_capacity_set", {"desired_capacity": 4}, "운영 앱 서버 대수 조정(4대)"),
        ("comment_filter", {"env": "dev", "blocked": False}, "댓글 필터 차단·해제(개발 해제)"),
        ("comment_filter", {"env": "prod"}, "댓글 필터 차단·해제(운영 차단)"),
        ("app_rollback", {"env": "prod", "tag": "20261105010203-abcdef0"}, "앱 이전 버전 되돌리기(운영 20261105010203-abcdef0)"),
        ("dev_ec2_stop_start", {"target": "dev-cking-app"}, "개발 EC2 중지·시작(dev-cking-app)"),
    ])
    def test_title(self, action, params, expected):
        assert actions.title(action, params) == expected


class TestBatchServerReplace:
    def test_busy(self):
        actions._autoscaling.describe_instance_refreshes.return_value = {"InstanceRefreshes": [{"Status": "InProgress"}]}
        assert check("batch_server_replace", env="dev") == (False, "서버 교체가 이미 진행 중이다(InProgress)")

    def test_check_does_not_start(self):
        actions._autoscaling.describe_instance_refreshes.return_value = {"InstanceRefreshes": [{"Status": "Successful"}]}
        ok, note = check("batch_server_replace", env="prod")
        assert ok and note.startswith("prod-cking-recommendation 서버를 새로 띄운다")
        actions._autoscaling.start_instance_refresh.assert_not_called()

    def test_run(self):
        actions._autoscaling.describe_instance_refreshes.return_value = {"InstanceRefreshes": []}
        actions._autoscaling.start_instance_refresh.return_value = {"InstanceRefreshId": "ref-1"}
        assert run("batch_server_replace", env="dev") == (True, "서버 교체를 시작했다(InstanceRefreshId `ref-1`)")
        actions._autoscaling.start_instance_refresh.assert_called_once_with(
            AutoScalingGroupName="dev-cking-recommendation", Preferences={"MinHealthyPercentage": 0})

    def test_bad_env(self):
        assert check("batch_server_replace", env="loadtest") == (False, "env는 dev나 prod다")


class TestAppServerReplace:
    ID = "i-0123456789abcdef0"

    @pytest.fixture
    def group(self):
        actions._autoscaling.describe_auto_scaling_instances.return_value = {
            "AutoScalingInstances": [{"AutoScalingGroupName": "prod-cking-app"}]}
        actions._elbv2.describe_target_groups.return_value = {"TargetGroups": [{"TargetGroupArn": "arn:tg"}]}

        def healthy(*ids):
            actions._elbv2.describe_target_health.return_value = {"TargetHealthDescriptions": [
                {"Target": {"Id": i}, "TargetHealth": {"State": state}} for i, state in ids]}

        return healthy

    @pytest.mark.parametrize("instance", ["", "i-123", "i-0123456789ABCDEF0", "x-0123456789abcdef0", "i-0123456789abcdef0; rm"])
    def test_bad_id(self, instance):
        assert check("app_server_replace", instance_id=instance) == (False, "instance_id 형식이 아니다")
        actions._autoscaling.describe_auto_scaling_instances.assert_not_called()

    def test_other_group(self, group):
        actions._autoscaling.describe_auto_scaling_instances.return_value = {
            "AutoScalingInstances": [{"AutoScalingGroupName": "prod-cking-monitor"}]}
        assert not check("app_server_replace", instance_id=self.ID)[0]

    def test_not_in_any_group(self, group):
        actions._autoscaling.describe_auto_scaling_instances.return_value = {"AutoScalingInstances": []}
        assert not check("app_server_replace", instance_id=self.ID)[0]

    def test_too_few_healthy(self, group):
        group((self.ID, "healthy"), ("i-0000000000000000b", "unhealthy"))
        ok, note = check("app_server_replace", instance_id=self.ID)
        assert not ok and "정상 서버가 1대" in note

    def test_check_counts_remaining(self, group):
        group((self.ID, "healthy"), ("i-0000000000000000b", "healthy"), ("i-0000000000000000c", "healthy"))
        ok, note = check("app_server_replace", instance_id=self.ID)
        assert ok and "남은 정상 서버 2대" in note
        actions._autoscaling.terminate_instance_in_auto_scaling_group.assert_not_called()

    def test_run_keeps_capacity(self, group):
        group((self.ID, "healthy"), ("i-0000000000000000b", "healthy"))
        actions._autoscaling.terminate_instance_in_auto_scaling_group.return_value = {"Activity": {"Description": "Terminating"}}
        assert run("app_server_replace", instance_id=self.ID) == (True, "교체를 시작했다: Terminating")
        actions._autoscaling.terminate_instance_in_auto_scaling_group.assert_called_once_with(
            InstanceId=self.ID, ShouldDecrementDesiredCapacity=False)


class TestAppCapacitySet:
    @pytest.fixture(autouse=True)
    def group(self):
        actions._autoscaling.describe_auto_scaling_groups.return_value = {
            "AutoScalingGroups": [{"MinSize": 2, "MaxSize": 6, "DesiredCapacity": 2}]}

    @pytest.mark.parametrize("desired", [None, 1, 7])
    def test_out_of_range(self, desired):
        assert check("app_capacity_set", desired_capacity=desired) == (False, "대수는 2~6대 안에서만 정한다")

    def test_same(self):
        assert check("app_capacity_set", desired_capacity=2) == (False, "지금 대수(2대)와 같다")

    def test_run(self):
        assert run("app_capacity_set", desired_capacity=4) == (True, "원하는 대수를 4대로 바꿨다")
        actions._autoscaling.set_desired_capacity.assert_called_once_with(
            AutoScalingGroupName="prod-cking-app", DesiredCapacity=4, HonorCooldown=False)

    def test_refused_run_does_not_change(self):
        assert run("app_capacity_set", desired_capacity=9) == (False, "실행하지 않았다: 대수는 2~6대 안에서만 정한다")
        actions._autoscaling.set_desired_capacity.assert_not_called()


class TestCommentFilter:
    def test_block(self):
        actions._lambda.get_function_concurrency.return_value = {}
        ok, note = check("comment_filter", env="prod", blocked=True)
        assert ok and "429" in note
        assert run("comment_filter", env="prod", blocked=True) == (True, "prod-cking-comment-filter 예약 동시성을 0으로 바꿨다(차단)")
        actions._lambda.put_function_concurrency.assert_called_once_with(
            FunctionName="prod-cking-comment-filter", ReservedConcurrentExecutions=0)

    @pytest.mark.parametrize("env,target", [("dev", 2), ("prod", 8)])
    def test_unblock(self, env, target):
        actions._lambda.get_function_concurrency.return_value = {"ReservedConcurrentExecutions": 0}
        assert check("comment_filter", env=env, blocked=False) == (True, f"예약 동시성을 {actions._to(target)} 되돌려 판정을 다시 받는다")

    def test_already(self):
        actions._lambda.get_function_concurrency.return_value = {"ReservedConcurrentExecutions": 0}
        assert check("comment_filter", env="dev") == (False, "이미 차단 상태다(예약 동시성 0)")


class TestAppRollback:
    TAG = "20261105010203-abcdef0"

    @pytest.fixture(autouse=True)
    def files(self):
        actions._s3.list_objects_v2.return_value = {"KeyCount": 1}
        actions._ssm.get_parameter.return_value = {"Parameter": {"Value": "20261105999999-1234567"}}

    @pytest.mark.parametrize("tag", ["", "latest", "20261105010203-ABCDEF0", "2026110501020-abcdef0", "20261105010203-abcdef0 ; x"])
    def test_bad_tag(self, tag):
        assert check("app_rollback", env="dev", tag=tag) == (False, "태그 형식(<빌드 시각 14자리>-<커밋 7자리>)이 아니다")

    def test_missing_release(self):
        actions._s3.list_objects_v2.return_value = {"KeyCount": 0}
        assert check("app_rollback", env="dev", tag=self.TAG) == (False, f"{self.TAG}의 배포 파일이 없다")
        assert actions._s3.list_objects_v2.call_args.kwargs["Bucket"] == actions.DEPLOY_BUCKETS["dev"]

    def test_current_prod_tag(self):
        actions._ssm.get_parameter.return_value = {"Parameter": {"Value": self.TAG}}
        assert check("app_rollback", env="prod", tag=self.TAG) == (False, f"{self.TAG}는 지금 운영에 배포된 태그다")

    def test_prod_check_does_not_call_github(self, github):
        ok, note = check("app_rollback", env="prod", tag=self.TAG)
        assert ok and "보안 수정 앞 태그" in note and "main 머지" in note
        assert github[0] == []

    @pytest.mark.parametrize("busy", ["deploy-prod.yml/runs?status=in_progress", "cicd.yml/runs?branch=main&event=push&status=queued"])
    def test_prod_run_refused_while_deploying(self, github, busy):
        calls, running = github
        running.add(busy)
        ok, result = run("app_rollback", env="prod", tag=self.TAG)
        assert not ok and "운영 배포" in result
        assert not any(method == "POST" for method, _, _ in calls)

    def test_prod_run_dispatches(self, github):
        calls, _ = github
        ok, result = run("app_rollback", env="prod", tag=self.TAG)
        assert ok
        assert calls[-1] == ("POST", f"{actions.PROD_DEPLOY_WORKFLOW}/dispatches", {"ref": "main", "inputs": {"image_tag": self.TAG}})
        assert len([c for c in calls if c[0] == "GET"]) == 4

    def test_dev_run_uses_document(self, documents):
        ok, result = run("app_rollback", env="dev", tag=self.TAG)
        assert ok and result.startswith("Success\n```")
        assert result.count("line") == 15
        assert documents == [(actions.DEV_SERVERS["dev-cking-app"], "dev-cking-app-rollback", {"tag": [self.TAG]}, 600)]

    def test_dev_check_mentions_develop(self):
        assert "develop 머지" in check("app_rollback", env="dev", tag=self.TAG)[1]


class TestDevRedis:
    @pytest.fixture
    def memory(self, monkeypatch):
        def set_body(body):
            monkeypatch.setattr(actions, "observability_query", lambda *a: json.dumps(body))
        return set_body

    def test_enough(self, memory, documents):
        memory({"series": [{"value": str(512 * 1024 * 1024)}]})
        assert check("dev_redis_maxmemory")[1].endswith("(서버 여유 512MiB). 컨테이너가 다시 뜨면 256MB로 돌아간다")
        assert run("dev_redis_maxmemory")[0]
        assert documents[0][1] == "dev-cking-redis-maxmemory"

    def test_too_little(self, memory, documents):
        memory({"series": [{"value": str(255 * 1024 * 1024)}]})
        ok, note = check("dev_redis_maxmemory")
        assert not ok and "255MiB" in note
        assert not run("dev_redis_maxmemory")[0]
        assert documents == []

    def test_no_value(self, memory):
        memory({"error": "timeout"})
        assert check("dev_redis_maxmemory") == (False, "개발 앱 서버 여유 메모리를 읽지 못했다: timeout")


class TestProdRedis:
    def group(self, status="available", node="cache.t4g.micro"):
        actions._elasticache.describe_replication_groups.return_value = {
            "ReplicationGroups": [{"Status": status, "CacheNodeType": node}]}

    def test_not_available(self):
        self.group(status="modifying")
        assert check("prod_redis_scale_up") == (False, "복제 그룹 상태가 modifying다")

    def test_no_next_size(self):
        self.group(node="cache.t4g.medium")
        assert not check("prod_redis_scale_up")[0]

    def test_run(self):
        self.group(node="cache.t4g.small")
        assert run("prod_redis_scale_up")[0]
        actions._elasticache.modify_replication_group.assert_called_once_with(
            ReplicationGroupId="prod-cking-redis", CacheNodeType="cache.t4g.medium", ApplyImmediately=True)


class TestDevEc2:
    def status(self, value):
        actions._ec2.describe_instance_status.return_value = {"InstanceStatuses": [{"SystemStatus": {"Status": value}}] if value else []}

    @pytest.mark.parametrize("target", ["", "prod-cking-app", "i-0000000000000000b"])
    def test_bad_target(self, target):
        assert check("dev_ec2_stop_start", target=target) == (False, "target은 dev-cking-app이나 dev-cking-observability다")

    @pytest.mark.parametrize("value,shown", [("ok", "ok"), (None, "unknown")])
    def test_only_when_impaired(self, value, shown):
        self.status(value)
        assert check("dev_ec2_stop_start", target="dev-cking-app")[1].startswith(f"시스템 상태 검사가 {shown}다")

    def test_run(self):
        self.status("impaired")
        ok, result = run("dev_ec2_stop_start", target="dev-cking-observability")
        assert ok and result == "dev-cking-observability(i-0000000000000000a)을 중지했다가 다시 시작했다"
        actions._ec2.stop_instances.assert_called_once_with(InstanceIds=["i-0000000000000000a"])
        actions._ec2.start_instances.assert_called_once_with(InstanceIds=["i-0000000000000000a"])


def test_dev_app_restart(documents):
    assert check("dev_app_restart")[0]
    assert documents == []
    assert run("dev_app_restart")[0]
    assert documents[0][1:] == ("dev-cking-app-restart", {}, 180)
