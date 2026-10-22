import base64
import datetime
import json
import os
import re
import time
import urllib.request

import boto3
from anthropic import beta_tool

REGION = "ap-northeast-2"
RUNBOOK_BASE = "https://raw.githubusercontent.com/URECA-Cking/Cking-Infra/main/docs/runbooks/"
OBSERVABILITY_INSTANCE = os.environ.get("OBSERVABILITY_INSTANCE_ID", "")
QUERY_DOCUMENT = os.environ.get("QUERY_DOCUMENT", "dev-cking-observability-query")
MAX_RESULT_CHARS = 12000
NAME_PATTERN = re.compile(r"^(dev|prod|loadtest)-cking-[a-z0-9-]+$")

_ssm = boto3.client("ssm", region_name=REGION)
_ec2 = boto3.client("ec2", region_name=REGION)
_autoscaling = boto3.client("autoscaling", region_name=REGION)
_elbv2 = boto3.client("elbv2", region_name=REGION)
_cloudwatch = boto3.client("cloudwatch", region_name=REGION)


def _default(value):
    if isinstance(value, datetime.datetime):
        return value.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return str(value)


def _json(value):
    text = json.dumps(value, ensure_ascii=False, default=_default)
    return text if len(text) <= MAX_RESULT_CHARS else text[:MAX_RESULT_CHARS] + "…(잘림)"


def _observability_query(kind, query, minutes):
    command = _ssm.send_command(
        InstanceIds=[OBSERVABILITY_INSTANCE],
        DocumentName=QUERY_DOCUMENT,
        Parameters={
            "kind": [kind],
            "query": [base64.b64encode(query.encode()).decode()],
            "minutes": [str(max(1, min(minutes, 10080)))],
        },
        TimeoutSeconds=60,
    )["Command"]["CommandId"]
    for _ in range(60):
        time.sleep(1)
        try:
            result = _ssm.get_command_invocation(CommandId=command, InstanceId=OBSERVABILITY_INSTANCE)
        except _ssm.exceptions.InvocationDoesNotExist:
            continue
        if result["Status"] in ("Pending", "InProgress", "Delayed"):
            continue
        return result["StandardOutputContent"] or result["StandardErrorContent"] or result["Status"]
    return "조회가 60초 안에 끝나지 않았다"


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
def query_prometheus(query: str, minutes: int = 0) -> str:
    """관측 서버 Prometheus에 PromQL을 실행한다. 시각은 UTC다.

    Args:
        query: PromQL. 개발 서버는 instance="dev-cking-app", "dev-cking-recommendation", "dev-cking-observability", 운영 앱 서버는 instance=~"prod-cking-app-.*".
        minutes: 0이면 지금 값 하나, 0보다 크면 지금부터 그만큼 거슬러 간 범위의 값(최대 30개 지점).
    """
    return _observability_query("prometheus_range" if minutes > 0 else "prometheus", query, minutes or 1)


@beta_tool
def query_loki(query: str, minutes: int = 60) -> str:
    """관측 서버 Loki에 LogQL을 실행한다. 로그 쿼리는 최근 줄부터 최대 50줄, 집계 쿼리는 범위 값을 돌려준다. 시각은 UTC다.

    Args:
        query: LogQL. 앱 로그는 {instance="dev-cking-app", container="app"}, 추천 배치 작업 로그는 {instance="dev-cking-recommendation", container="journal"}.
        minutes: 지금부터 거슬러 갈 범위(분).
    """
    return _observability_query("loki", query, minutes)


@beta_tool
def describe_scaling_activities(group: str, terminating_only: bool = False) -> str:
    """서버 그룹(Auto Scaling) 활동을 최근 것부터 15건 돌려준다. 띄우기 실패, 시작 대기에서 버려짐, 종료 원인이 여기에 남는다.

    Args:
        group: 서버 그룹 이름. 예: dev-cking-recommendation, prod-cking-app, prod-cking-monitor, prod-cking-recommendation.
        terminating_only: True면 종료 활동만. 띄우기 실패가 이어지면 종료 활동이 최근 15건에 밀리므로 이것으로 따로 본다.
    """
    if not NAME_PATTERN.fullmatch(group):
        return "크킹 서버 그룹 이름만 조회한다"
    activities = []
    for page in _autoscaling.get_paginator("describe_scaling_activities").paginate(AutoScalingGroupName=group):
        for item in page["Activities"]:
            if terminating_only and not item["Description"].startswith("Terminating"):
                continue
            activities.append({
                "start": item["StartTime"],
                "status": item["StatusCode"],
                "description": item["Description"][:200],
                "cause": item.get("Cause", "")[:300],
                "status_message": item.get("StatusMessage", "")[:300],
            })
            if len(activities) >= 15:
                return _json(activities)
    return _json(activities)


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
                          minutes: int = 60, period: int = 60) -> str:
    """CloudWatch 지표 값을 돌려준다(RDS, ElastiCache, ALB, EC2 상태 검사 등). 시각은 UTC다.

    Args:
        namespace: 예: AWS/RDS, AWS/ElastiCache, AWS/ApplicationELB, AWS/EC2.
        metric_name: 예: CPUUtilization, DatabaseMemoryUsagePercentage, HealthyHostCount.
        dimensions: 예: {"DBInstanceIdentifier": "prod-cking-mysql"}.
        statistic: Average, Maximum, Minimum, Sum 중 하나.
        minutes: 지금부터 거슬러 갈 범위(분, 최대 1440).
        period: 집계 간격(초, 60의 배수).
    """
    end = datetime.datetime.now(datetime.timezone.utc)
    points = _cloudwatch.get_metric_statistics(
        Namespace=namespace, MetricName=metric_name,
        Dimensions=[{"Name": k, "Value": v} for k, v in dimensions.items()],
        StartTime=end - datetime.timedelta(minutes=max(1, min(minutes, 1440))), EndTime=end,
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


TOOLS = [
    read_runbook, query_prometheus, query_loki, describe_scaling_activities, describe_instances,
    get_console_output, describe_target_health, get_cloudwatch_metric, describe_alarm_history,
]
