import datetime
import json
import re
import urllib.request
from typing import Literal

import boto3
from anthropic import beta_tool

import actions
from commands import observability_query as _observability_query
from commands import utc_time as _utc_time

REGION = "ap-northeast-2"
RUNBOOK_BASE = "https://raw.githubusercontent.com/URECA-Cking/Cking-Infra/main/docs/runbooks/"
MAX_RESULT_CHARS = 12000
NAME_PATTERN = re.compile(r"^(dev|prod|loadtest)-cking-[a-z0-9-]+$")

_ec2 = boto3.client("ec2", region_name=REGION)
_autoscaling = boto3.client("autoscaling", region_name=REGION)
_elbv2 = boto3.client("elbv2", region_name=REGION)
_cloudwatch = boto3.client("cloudwatch", region_name=REGION)
_s3 = boto3.client("s3", region_name=REGION)
_ssm = boto3.client("ssm", region_name=REGION)

# 진단 한 번에 제안된 조치. diagnose가 진단마다 비운다.
PROPOSAL = {}


def _default(value):
    if isinstance(value, datetime.datetime):
        return value.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return str(value)


def _json(value):
    text = json.dumps(value, ensure_ascii=False, default=_default)
    return text if len(text) <= MAX_RESULT_CHARS else text[:MAX_RESULT_CHARS] + "…(잘림)"


@beta_tool
def read_runbook(name: str) -> str:
    """docs/runbooks의 런북을 main 브랜치에서 읽는다.

    Args:
        name: 확장자 없는 파일 이름. 경보 runbook_url의 파일 이름(예: cking-recommendation-stalled), README, stream 등.
    """
    if not re.fullmatch(r"[A-Za-z0-9-]+", name):
        return "이름은 영문·숫자·하이픈만 쓴다"
    try:
        with urllib.request.urlopen(RUNBOOK_BASE + name + ".md", timeout=10) as response:
            return response.read().decode()[:30000]
    except Exception as error:
        return f"런북을 읽지 못했다: {error}"


@beta_tool
def query_prometheus(query: str, minutes: int = 0, end: str = "") -> str:
    """관측 서버 Prometheus에 PromQL을 실행한다. 시각은 UTC다.

    Args:
        query: PromQL. 개발 서버는 instance="dev-cking-app", "dev-cking-recommendation", "dev-cking-observability", 운영 앱 서버는 instance=~"prod-cking-app-.*".
        minutes: 0이면 end 시각의 값 하나, 0보다 크면 end부터 그만큼 거슬러 간 범위의 값(최대 30개 지점).
        end: 조회 끝 시각(UTC, 예: 2026-10-23T00:20:00Z). 비우면 지금. 경보 시점은 경보 시작 시각 뒤 몇 분으로 본다.
    """
    return _observability_query("prometheus_range" if minutes > 0 else "prometheus", query, minutes or 1, end)


@beta_tool
def query_loki(query: str, minutes: int = 60, end: str = "") -> str:
    """관측 서버 Loki에 LogQL을 실행한다. 로그 쿼리는 end에 가까운 줄부터 최대 50줄과 전체 줄 수(lines_total), 집계 쿼리는 범위 값을 돌려준다. 시각은 UTC다.

    Args:
        query: LogQL. 앱 로그는 {instance="dev-cking-app", container="app"}, 추천 배치 작업 로그는 {instance="dev-cking-recommendation", container="journal"}.
        minutes: end부터 거슬러 갈 범위(분).
        end: 조회 끝 시각(UTC, 예: 2026-10-23T00:20:00Z). 비우면 지금.
    """
    return _observability_query("loki", query, minutes, end)


@beta_tool
def describe_scaling_activities(group: str, since: str = "", until: str = "", terminating_only: bool = False) -> str:
    """서버 그룹(Auto Scaling) 활동을 돌려준다. 띄우기 실패, 시작 대기에서 버려짐, 종료 원인이 여기에 남는다.
    since를 주면 그 범위의 활동을 시간순으로, 범위 전체의 종류·상태별 건수(counts)와 실패 사유별 건수(failure_reasons)와 함께 돌려준다.
    연속된 같은 실패는 한 항목으로 묶고 횟수(repeated)와 마지막 시각(last_start)을 단다.
    since가 없으면 최근 것부터 15건이다. 횟수는 목록을 세지 말고 counts를 쓴다.

    Args:
        group: 서버 그룹 이름. 예: dev-cking-recommendation, prod-cking-app, prod-cking-monitor, prod-cking-recommendation.
        since: 범위 시작(UTC, 예: 2026-10-22T23:30:00Z). 경보 시작 시각 30~60분 전부터 본다.
        until: 범위 끝(UTC). 비우면 지금.
        terminating_only: True면 종료 활동만.
    """
    if not NAME_PATTERN.fullmatch(group):
        return "크킹 서버 그룹 이름만 조회한다"
    start = _utc_time(since) if since else None
    end = _utc_time(until) if until else None
    activities, counts, reasons = [], {}, {}
    for page in _autoscaling.get_paginator("describe_scaling_activities").paginate(AutoScalingGroupName=group):
        for item in page["Activities"]:
            if end and item["StartTime"] > end:
                continue
            if start and item["StartTime"] < start:
                break
            if terminating_only and not item["Description"].startswith("Terminating"):
                continue
            key = f"{item['Description'].split(' ')[0]} {item['StatusCode']}"
            counts[key] = counts.get(key, 0) + 1
            if item["StatusCode"] != "Successful":
                reason = item.get("StatusMessage", "")[:90]
                reasons[reason] = reasons.get(reason, 0) + 1
            if start:
                entry = {"start": item["StartTime"], "status": item["StatusCode"], "description": item["Description"][:120]}
                if item.get("StatusMessage"):
                    entry["status_message"] = item["StatusMessage"][:150]
                if item["Description"].startswith("Terminating"):
                    entry["cause"] = item.get("Cause", "")[:200]
            else:
                entry = {
                    "start": item["StartTime"],
                    "status": item["StatusCode"],
                    "description": item["Description"][:200],
                    "cause": item.get("Cause", "")[:300],
                    "status_message": item.get("StatusMessage", "")[:300],
                }
            activities.append(entry)
            if not start and len(activities) >= 15:
                return _json(activities)
        else:
            continue
        break
    if not start:
        return _json(activities)
    activities.reverse()
    grouped = []
    for entry in activities:
        last = grouped[-1] if grouped else None
        if (last and entry["status"] != "Successful" and last["status"] == entry["status"]
                and last.get("status_message") == entry.get("status_message")):
            last["repeated"] = last.get("repeated", 1) + 1
            last["last_start"] = entry["start"]
            continue
        grouped.append(entry)
    return _json({"counts": counts, "failure_reasons": reasons, "total": len(activities), "activities": grouped[:40]})


@beta_tool
def describe_instances(name: str = "", instance_ids: list[str] | None = None) -> str:
    """EC2 서버 상태를 돌려준다. 종료된 서버는 종료 뒤 약 1시간만 조회되고, 종료 이유(StateReason, 예: Server.SpotInstanceTermination)가 함께 나온다.

    Args:
        name: 이름표(Name) 값. 예: dev-cking-app, dev-cking-recommendation, prod-cking-app.
        instance_ids: 서버 ID 목록. name 대신 쓴다.
    """
    if instance_ids:
        kwargs = {"InstanceIds": instance_ids[:20]}
    elif NAME_PATTERN.fullmatch(name):
        kwargs = {"Filters": [{"Name": "tag:Name", "Values": [name]}]}
    else:
        return "크킹 이름표나 서버 ID로만 조회한다"
    rows = []
    for reservation in _ec2.describe_instances(**kwargs)["Reservations"]:
        for item in reservation["Instances"]:
            rows.append({
                "id": item["InstanceId"],
                "state": item["State"]["Name"],
                "state_reason": item.get("StateReason", {}).get("Message"),
                "type": item["InstanceType"],
                "lifecycle": item.get("InstanceLifecycle", "on-demand"),
                "az": item["Placement"]["AvailabilityZone"],
                "launch_time": item["LaunchTime"],
                "private_ip": item.get("PrivateIpAddress"),
            })
    return _json(rows)


@beta_tool
def get_console_output(instance_id: str) -> str:
    """서버 부팅 출력(cloud-init 포함)에서 오류 줄과 마지막 40줄을 돌려준다. 종료된 서버도 몇 시간은 받아진다.

    Args:
        instance_id: 서버 ID(i-로 시작).
    """
    if not re.fullmatch(r"i-[0-9a-f]{8,17}", instance_id):
        return "서버 ID 형식이 아니다"
    output = _ec2.get_console_output(InstanceId=instance_id, Latest=True).get("Output", "")
    lines = output.splitlines()
    errors = [line for line in lines if re.search(r"An error occurred|ParameterNotFound|ABANDON|헬스체크 실패|추천 배치 값이|Traceback|failed", line)]
    return _json({"error_lines": errors[-30:], "last_lines": lines[-40:]})


@beta_tool
def describe_target_health(target_group: str) -> str:
    """ALB 대상 그룹의 대상별 상태와 비정상 사유를 돌려준다.

    Args:
        target_group: 대상 그룹 이름. 예: prod-cking-app-tg.
    """
    if not NAME_PATTERN.fullmatch(target_group):
        return "크킹 대상 그룹 이름만 조회한다"
    arn = _elbv2.describe_target_groups(Names=[target_group])["TargetGroups"][0]["TargetGroupArn"]
    rows = [
        {"id": item["Target"]["Id"], "state": item["TargetHealth"]["State"], "reason": item["TargetHealth"].get("Reason"),
         "description": item["TargetHealth"].get("Description")}
        for item in _elbv2.describe_target_health(TargetGroupArn=arn)["TargetHealthDescriptions"]
    ]
    return _json(rows)


@beta_tool
def get_cloudwatch_metric(namespace: str, metric_name: str, dimensions: dict[str, str], statistic: str = "Average",
                          minutes: int = 60, period: int = 60, end: str = "") -> str:
    """CloudWatch 지표 값을 돌려준다(RDS, ElastiCache, ALB, EC2 상태 검사 등). 시각은 UTC다.

    Args:
        namespace: 예: AWS/RDS, AWS/ElastiCache, AWS/ApplicationELB, AWS/EC2.
        metric_name: 예: CPUUtilization, DatabaseMemoryUsagePercentage, HealthyHostCount.
        dimensions: 예: {"DBInstanceIdentifier": "prod-cking-mysql"}.
        statistic: Average, Maximum, Minimum, Sum 중 하나.
        minutes: end부터 거슬러 갈 범위(분, 최대 1440).
        period: 집계 간격(초, 60의 배수).
        end: 조회 끝 시각(UTC, 예: 2026-10-23T00:20:00Z). 비우면 지금.
    """
    end_time = min(_utc_time(end), datetime.datetime.now(datetime.timezone.utc)) if end else datetime.datetime.now(datetime.timezone.utc)
    points = _cloudwatch.get_metric_statistics(
        Namespace=namespace, MetricName=metric_name,
        Dimensions=[{"Name": k, "Value": v} for k, v in dimensions.items()],
        StartTime=end_time - datetime.timedelta(minutes=max(1, min(minutes, 1440))), EndTime=end_time,
        Period=max(60, period - period % 60), Statistics=[statistic],
    )["Datapoints"]
    points.sort(key=lambda p: p["Timestamp"])
    return _json([[p["Timestamp"], p[statistic]] for p in points[-60:]])


@beta_tool
def describe_alarm_history(alarm_name: str) -> str:
    """CloudWatch 경보의 최근 상태 변화 20건을 돌려준다.

    Args:
        alarm_name: 경보 이름. 예: prod-cking-alb-few-healthy-targets.
    """
    items = _cloudwatch.describe_alarm_history(AlarmName=alarm_name, HistoryItemType="StateUpdate", MaxRecords=20)["AlarmHistoryItems"]
    return _json([{"time": i["Timestamp"], "summary": i["HistorySummary"]} for i in items])


@beta_tool
def list_release_tags(env: str) -> str:
    """앱 배포 태그를 최근 것부터 10개 돌려준다. 운영은 지금 배포된 태그(RELEASE_TAG)도 함께 준다. 되돌리기를 제안하기 전에 본다.

    Args:
        env: dev 또는 prod.
    """
    if env not in actions.DEPLOY_BUCKETS:
        return "env는 dev나 prod다"
    pages = _s3.get_paginator("list_objects_v2").paginate(Bucket=actions.DEPLOY_BUCKETS[env], Prefix="releases/", Delimiter="/")
    tags = sorted((p["Prefix"].split("/")[1] for page in pages for p in page.get("CommonPrefixes", [])), reverse=True)
    result = {"tags": tags[:10]}
    if env == "prod":
        result["current"] = _ssm.get_parameter(Name="/cking/prod/RELEASE_TAG")["Parameter"]["Value"]
    return _json(result)


@beta_tool
def propose_action(
    action: Literal["batch_server_replace", "app_server_replace", "app_capacity_set", "comment_filter", "app_rollback",
                    "dev_app_restart", "dev_redis_maxmemory", "prod_redis_scale_up", "dev_ec2_stop_start"],
    env: str = "", instance_id: str = "", desired_capacity: int = 0, tag: str = "", blocked: bool = True, target: str = "",
) -> str:
    """판단이 "지금 조치 필요"이고 런북의 조치가 아래 목록에 있을 때 그 조치 하나를 승인 버튼으로 제안한다.
    실행은 승인자가 버튼을 누를 때 한다. 도구가 실행 직전 검사(런북의 하면 안 되는 것)를 하고, 통과하면 버튼이 붙는다.
    batch_server_replace(env): 추천 배치 서버 교체. app_server_replace(instance_id): 운영 앱 서버 1대 교체.
    app_capacity_set(desired_capacity): 운영 앱 서버 대수. comment_filter(env, blocked): 댓글 필터 차단(true)·해제(false).
    app_rollback(env, tag): 앱 이전 버전 되돌리기(태그는 list_release_tags로 고른다). dev_app_restart: 개발 앱 컨테이너 재시작.
    dev_redis_maxmemory: 개발 Redis 한도 256→384MB. prod_redis_scale_up: 운영 ElastiCache 노드 한 단계 상향.
    dev_ec2_stop_start(target): 개발 EC2(dev-cking-app, dev-cking-observability) 중지·시작.

    Args:
        action: 조치 이름.
        env: dev 또는 prod(필요한 조치만).
        instance_id: app_server_replace의 서버 ID.
        desired_capacity: app_capacity_set의 대수.
        tag: app_rollback의 태그.
        blocked: comment_filter에서 차단이면 true, 해제면 false.
        target: dev_ec2_stop_start의 서버 이름.
    """
    params = {"env": env, "instance_id": instance_id, "desired_capacity": desired_capacity, "tag": tag, "blocked": blocked, "target": target}
    params = {k: v for k, v in params.items() if v not in ("", 0) or k == "blocked"}
    ok, note = actions.check(action, params)
    PROPOSAL.clear()
    PROPOSAL.update({"action": action, "params": params, "ok": ok, "note": note, "title": actions.title(action, params)})
    if ok:
        return f"제안을 기록했다. 버튼이 붙는다. 영향: {note}"
    return f"실행 직전 검사를 통과하지 못해 버튼이 붙지 않는다: {note}. 이 이유를 *사람이 볼 것*에 적는다"


TOOLS = [
    read_runbook, query_prometheus, query_loki, describe_scaling_activities, describe_instances,
    get_console_output, describe_target_health, get_cloudwatch_metric, describe_alarm_history,
    list_release_tags, propose_action,
]
