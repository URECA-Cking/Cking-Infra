"""승인 버튼으로 실행하는 런북 조치. 조치마다 입력 검사, 실행 직전 검사(런북의 "하면 안 되는 것"), 실행을 둔다."""
import json
import os
import re
import urllib.request

import boto3

from commands import observability_query, run_document

REGION = "ap-northeast-2"
TAG_PATTERN = re.compile(r"^[0-9]{14}-[0-9a-f]{7}$")
INSTANCE_PATTERN = re.compile(r"^i-[0-9a-f]{8,17}$")
ENV_LABELS = {"dev": "개발", "prod": "운영"}
DEPLOY_BUCKETS = {"dev": "dev-cking-deploy-551372961758", "prod": "prod-cking-deploy-551372961758-ap-northeast-2-an"}
FILTER_CONCURRENCY = {"dev": 2, "prod": 8}
NEXT_CACHE_NODE = {"cache.t4g.micro": "cache.t4g.small", "cache.t4g.small": "cache.t4g.medium"}
DEV_SERVERS = {
    "dev-cking-app": os.environ.get("DEV_APP_INSTANCE_ID", ""),
    "dev-cking-observability": os.environ.get("OBSERVABILITY_INSTANCE_ID", ""),
}
DOCUMENTS = {
    "restart": "dev-cking-app-restart",
    "redis": "dev-cking-redis-maxmemory",
    "rollback": "dev-cking-app-rollback",
}
GITHUB_TOKEN_PARAMETER = "/cking/dev/monitoring/GITHUB_ACTIONS_TOKEN"
PROD_DEPLOY_WORKFLOW = "https://api.github.com/repos/URECA-Cking/Cking-BE/actions/workflows/deploy-prod.yml"
REDIS_RAISE_MIN_AVAILABLE_MIB = 256
REFRESH_BUSY = ("Pending", "InProgress", "Cancelling", "RollbackInProgress", "Baking")

_autoscaling = boto3.client("autoscaling", region_name=REGION)
_elbv2 = boto3.client("elbv2", region_name=REGION)
_lambda = boto3.client("lambda", region_name=REGION)
_elasticache = boto3.client("elasticache", region_name=REGION)
_ec2 = boto3.client("ec2", region_name=REGION)
_s3 = boto3.client("s3", region_name=REGION)
_ssm = boto3.client("ssm", region_name=REGION)


class Refused(Exception):
    pass


def _env(params):
    if params.get("env") not in ENV_LABELS:
        raise Refused("env는 dev나 prod다")
    return params["env"]


def _to(number):
    # 숫자 뒤 조사: 0·3·6은 받침이 있어 "으로", 나머지는 "로"(1·7·8은 ㄹ 받침)
    return f"{number}{'으로' if str(number)[-1] in '036' else '로'}"


def _tail(text, lines=15):
    return "\n".join((text or "").strip().splitlines()[-lines:])


def _github(method, url, payload=None):
    token = _ssm.get_parameter(Name=GITHUB_TOKEN_PARAMETER, WithDecryption=True)["Parameter"]["Value"]
    request = urllib.request.Request(
        url, method=method, data=json.dumps(payload).encode() if payload else None,
        headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"},
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        body = response.read()
    return json.loads(body) if body else {}


# 추천 배치 서버 교체 (recommendation-batch.md)
def batch_server_replace(params, stage):
    env = _env(params)
    group = f"{env}-cking-recommendation"
    refreshes = _autoscaling.describe_instance_refreshes(AutoScalingGroupName=group, MaxRecords=1)["InstanceRefreshes"]
    if refreshes and refreshes[0]["Status"] in REFRESH_BUSY:
        raise Refused(f"서버 교체가 이미 진행 중이다({refreshes[0]['Status']})")
    if stage == "check":
        return f"{group} 서버를 새로 띄운다. 새 서버가 상태 디스크를 이어받아 처리 기록은 남고, 뜰 때까지 배치가 멈춘다"
    refresh = _autoscaling.start_instance_refresh(AutoScalingGroupName=group, Preferences={"MinHealthyPercentage": 0})
    return f"서버 교체를 시작했다(InstanceRefreshId `{refresh['InstanceRefreshId']}`)"


def _healthy_targets():
    group = _elbv2.describe_target_groups(Names=["prod-cking-app-tg"])["TargetGroups"][0]["TargetGroupArn"]
    targets = _elbv2.describe_target_health(TargetGroupArn=group)["TargetHealthDescriptions"]
    return {t["Target"]["Id"] for t in targets if t["TargetHealth"]["State"] == "healthy"}


# 운영 앱 서버 1대 교체 (README 운영)
def app_server_replace(params, stage):
    instance = params.get("instance_id", "")
    if not INSTANCE_PATTERN.fullmatch(instance):
        raise Refused("instance_id 형식이 아니다")
    found = _autoscaling.describe_auto_scaling_instances(InstanceIds=[instance])["AutoScalingInstances"]
    if not found or found[0]["AutoScalingGroupName"] != "prod-cking-app":
        raise Refused("운영 앱 서버 그룹(prod-cking-app)의 서버가 아니다")
    healthy = _healthy_targets()
    if len(healthy) < 2:
        raise Refused(f"정상 서버가 {len(healthy)}대라 교체하지 않는다(런북: 2대 미만이면 교체하지 않는다)")
    if stage == "check":
        return (f"{instance}만 새로 띄운다(대수 유지). 새 서버가 자기 검사를 통과할 때까지 남은 정상 서버 "
                f"{len(healthy - {instance})}대가 요청을 받고, 이 서버 안의 상태는 사라진다")
    activity = _autoscaling.terminate_instance_in_auto_scaling_group(InstanceId=instance, ShouldDecrementDesiredCapacity=False)
    return f"교체를 시작했다: {activity['Activity']['Description']}"


# 운영 앱 서버 대수 조정 (cking-stream-lag.md)
def app_capacity_set(params, stage):
    desired = int(params.get("desired_capacity") or 0)
    group = _autoscaling.describe_auto_scaling_groups(AutoScalingGroupNames=["prod-cking-app"])["AutoScalingGroups"][0]
    if not group["MinSize"] <= desired <= group["MaxSize"]:
        raise Refused(f"대수는 {group['MinSize']}~{group['MaxSize']}대 안에서만 정한다")
    if desired == group["DesiredCapacity"]:
        raise Refused(f"지금 대수({desired}대)와 같다")
    if stage == "check":
        return f"운영 앱 서버를 {group['DesiredCapacity']}대에서 {desired}대로 바꾼다. 목표 추적 정책이 요청 수를 보고 다시 바꿀 수 있다"
    _autoscaling.set_desired_capacity(AutoScalingGroupName="prod-cking-app", DesiredCapacity=desired, HonorCooldown=False)
    return f"원하는 대수를 {desired}대로 바꿨다"


# 댓글 필터 즉시 차단·해제 (comment-filter.md)
def comment_filter(params, stage):
    env = _env(params)
    blocked = bool(params.get("blocked", True))
    function = f"{env}-cking-comment-filter"
    target = 0 if blocked else FILTER_CONCURRENCY[env]
    current = _lambda.get_function_concurrency(FunctionName=function).get("ReservedConcurrentExecutions")
    if current == target:
        raise Refused(f"이미 {'차단' if blocked else '해제'} 상태다(예약 동시성 {target})")
    if stage == "check":
        if blocked:
            return "모든 필터 호출이 429로 거절되고 새 댓글은 판정 없이 보인다. 차단이 15분을 넘으면 그동안 쓴 댓글은 해제 뒤에도 판정되지 않는다"
        return f"예약 동시성을 {_to(target)} 되돌려 판정을 다시 받는다"
    _lambda.put_function_concurrency(FunctionName=function, ReservedConcurrentExecutions=target)
    return f"{function} 예약 동시성을 {_to(target)} 바꿨다({'차단' if blocked else '해제'})"


# 앱 이전 버전 되돌리기 (deploy-failed.md)
def app_rollback(params, stage):
    env = _env(params)
    tag = params.get("tag", "")
    if not TAG_PATTERN.fullmatch(tag):
        raise Refused("태그 형식(<빌드 시각 14자리>-<커밋 7자리>)이 아니다")
    if not _s3.list_objects_v2(Bucket=DEPLOY_BUCKETS[env], Prefix=f"releases/{tag}/", MaxKeys=1).get("KeyCount"):
        raise Refused(f"{tag}의 배포 파일이 없다")
    if env == "prod":
        current = _ssm.get_parameter(Name="/cking/prod/RELEASE_TAG")["Parameter"]["Value"]
        if tag == current:
            raise Refused(f"{tag}는 지금 운영에 배포된 태그다")
        if stage == "run":
            for status in ("in_progress", "queued"):
                if _github("GET", f"{PROD_DEPLOY_WORKFLOW}/runs?status={status}&per_page=1").get("total_count"):
                    raise Refused("Deploy to prod가 실행 중이다. 끝난 뒤 다시 본다")
    if stage == "check":
        branch = "main" if env == "prod" else "develop"
        warning = "보안 수정 앞 태그로 되돌리지 않는다. " if env == "prod" else ""
        return (f"{ENV_LABELS[env]} 앱을 이전 버전(태그 {tag})으로 되돌린다. DB 마이그레이션이 포함된 배포 뒤라면 이전 코드가 지금 스키마에서 "
                f"도는지 확인했을 때만 누른다. {warning}되돌린 뒤 {branch} 머지가 들어오면 그 버전이 다시 배포된다")
    if env == "prod":
        _github("POST", f"{PROD_DEPLOY_WORKFLOW}/dispatches", {"ref": "main", "inputs": {"image_tag": tag}})
        return f"Cking-BE `Deploy to prod`를 실행했다(image_tag `{tag}`). 진행은 Cking-BE Actions에서 본다"
    status, output = run_document(DEV_SERVERS["dev-cking-app"], DOCUMENTS["rollback"], {"tag": [tag]}, 600)
    return f"{status}\n```{_tail(output)}```"


# 개발 앱 컨테이너 재시작 (cking-stream-stopped.md)
def dev_app_restart(params, stage):
    if stage == "check":
        return "개발 앱 컨테이너(cking-app)를 다시 띄운다. 뜨는 수십 초 동안 개발 API가 멈춘다"
    status, output = run_document(DEV_SERVERS["dev-cking-app"], DOCUMENTS["restart"], {}, 180)
    return f"{status}\n```{_tail(output)}```"


def _available_mib():
    body = json.loads(observability_query("prometheus", 'node_memory_MemAvailable_bytes{instance="dev-cking-app"}', 1))
    series = body.get("series") or []
    if not series:
        raise Refused(f"개발 앱 서버 여유 메모리를 읽지 못했다: {body.get('error', '값 없음')}")
    return int(float(series[0]["value"]) / 1024 / 1024)


# 개발 Redis 메모리 한도 임시 상향 (cking-redis-rejected.md)
def dev_redis_maxmemory(params, stage):
    available = _available_mib()
    if available < REDIS_RAISE_MIN_AVAILABLE_MIB:
        raise Refused(f"서버 여유 메모리가 {available}MiB라 올리지 않는다(올리는 폭 128MB의 2배인 256MiB 이상일 때만)")
    if stage == "check":
        return f"개발 Redis 한도를 256MB에서 384MB로 올린다(서버 여유 {available}MiB). 컨테이너가 다시 뜨면 256MB로 돌아간다"
    status, output = run_document(DEV_SERVERS["dev-cking-app"], DOCUMENTS["redis"], {}, 60)
    return f"{status}\n```{_tail(output)}```"


# 운영 ElastiCache 노드 크기 상향 (cking-redis-rejected.md 운영, prod-elasticache.md)
def prod_redis_scale_up(params, stage):
    group = _elasticache.describe_replication_groups(ReplicationGroupId="prod-cking-redis")["ReplicationGroups"][0]
    if group["Status"] != "available":
        raise Refused(f"복제 그룹 상태가 {group['Status']}다")
    current = group["CacheNodeType"]
    if current not in NEXT_CACHE_NODE:
        raise Refused(f"{current}의 다음 크기가 정해져 있지 않다")
    if stage == "check":
        return (f"노드 크기를 한 단계 올린다({current} → {NEXT_CACHE_NODE[current]}, 노드 2개). 진행 중에도 요청을 받지만 끝날 때까지 "
                "시간이 걸리고 비용이 는다. 끝나면 envs/prod/cache.tf 크기를 같은 값으로 맞추는 PR이 필요하다")
    _elasticache.modify_replication_group(
        ReplicationGroupId="prod-cking-redis", CacheNodeType=NEXT_CACHE_NODE[current], ApplyImmediately=True,
    )
    return f"노드 크기 변경을 시작했다({current} → {NEXT_CACHE_NODE[current]}). envs/prod/cache.tf를 같은 값으로 맞추는 PR이 남았다"


# 개발 EC2 중지·시작 (ec2-system-check.md)
def dev_ec2_stop_start(params, stage):
    target = params.get("target", "")
    instance = DEV_SERVERS.get(target)
    if not instance:
        raise Refused("target은 dev-cking-app이나 dev-cking-observability다")
    statuses = _ec2.describe_instance_status(InstanceIds=[instance], IncludeAllInstances=True)["InstanceStatuses"]
    system = statuses[0]["SystemStatus"]["Status"] if statuses else "unknown"
    if system != "impaired":
        raise Refused(f"시스템 상태 검사가 {system}다. 실패(impaired)로 남아 있을 때만 중지·시작한다")
    if stage == "check":
        stopped = "개발 앱이 멈춘다" if target == "dev-cking-app" else "지표·로그 저장과 Grafana 경보가 멈춘다"
        return f"{target}을 중지한 뒤 시작해 다른 하드웨어로 옮긴다. 그동안 {stopped}"
    _ec2.stop_instances(InstanceIds=[instance])
    _ec2.get_waiter("instance_stopped").wait(InstanceIds=[instance], WaiterConfig={"Delay": 10, "MaxAttempts": 50})
    _ec2.start_instances(InstanceIds=[instance])
    _ec2.get_waiter("instance_running").wait(InstanceIds=[instance], WaiterConfig={"Delay": 10, "MaxAttempts": 30})
    return f"{target}({instance})을 중지했다가 다시 시작했다"


ACTIONS = {
    "batch_server_replace": ("추천 배치 서버 교체", batch_server_replace),
    "app_server_replace": ("운영 앱 서버 1대 교체", app_server_replace),
    "app_capacity_set": ("운영 앱 서버 대수 조정", app_capacity_set),
    "comment_filter": ("댓글 필터 차단·해제", comment_filter),
    "app_rollback": ("앱 이전 버전 되돌리기", app_rollback),
    "dev_app_restart": ("개발 앱 컨테이너 재시작", dev_app_restart),
    "dev_redis_maxmemory": ("개발 Redis 메모리 한도 임시 상향", dev_redis_maxmemory),
    "prod_redis_scale_up": ("운영 ElastiCache 노드 크기 상향", prod_redis_scale_up),
    "dev_ec2_stop_start": ("개발 EC2 중지·시작", dev_ec2_stop_start),
}


def title(action, params):
    name = ACTIONS[action][0]
    detail = params.get("env") and ENV_LABELS.get(params["env"]) or ""
    for key in ("instance_id", "tag", "target"):
        if params.get(key):
            detail = f"{detail} {params[key]}".strip()
    if action == "app_capacity_set":
        detail = f"{params.get('desired_capacity')}대"
    if action == "comment_filter":
        detail = f"{detail} {'차단' if params.get('blocked', True) else '해제'}"
    return f"{name}({detail})" if detail else name


def check(action, params):
    """(통과 여부, 확인 창에 보일 영향 또는 거절 이유)를 돌려준다."""
    if action not in ACTIONS:
        return False, "목록에 없는 조치다"
    try:
        return True, ACTIONS[action][1](params, "check")
    except Refused as refused:
        return False, str(refused)


def run(action, params):
    """실행한다. 조치 함수가 실행 전에 같은 검사를 다시 한다. (성공 여부, 결과)를 돌려준다."""
    try:
        return True, ACTIONS[action][1](params, "run")
    except Refused as refused:
        return False, f"실행하지 않았다: {refused}"
