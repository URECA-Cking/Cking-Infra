import datetime
import json
import os
import re
import time
import urllib.request

import boto3
from botocore.exceptions import ClientError

from diagnose import diagnose

REGION = "ap-northeast-2"
KST = datetime.timezone(datetime.timedelta(hours=9))
STATE_TABLE = os.environ["STATE_TABLE"]
DAILY_LIMIT = int(os.environ.get("DAILY_LIMIT", "12"))
PROD_CHATBOT_TOPIC = os.environ.get("PROD_CHATBOT_TOPIC", "")
# 진단은 그 경보가 가는 채널에 남긴다. 운영 CloudWatch 경보와 서버 띄우기 실패는 Amazon Q 채널(prod-aws)이다.
WEBHOOK_PARAMETERS = {
    "dev": "/cking/dev/monitoring/SLACK_ALERT_WEBHOOK_URL",
    "prod": "/cking/dev/monitoring/SLACK_PROD_ALERT_WEBHOOK_URL",
}
RUNBOOK_URL = re.compile(r"https://github\.com/URECA-Cking/Cking-Infra/blob/main/docs/runbooks/([A-Za-z0-9-]+)\.md")

_dynamodb = boto3.client("dynamodb", region_name=REGION)
_ssm = boto3.client("ssm", region_name=REGION)
_sns = boto3.client("sns", region_name=REGION)
_webhooks = {}


def handler(event, context):
    for record in event.get("Records", []):
        try:
            message = json.loads(record["Sns"]["Message"])
        except (KeyError, json.JSONDecodeError):
            print("SNS 메시지가 JSON이 아니어서 건너뛴다")
            continue
        alert = parse(message)
        if alert is None:
            continue
        if not claim(alert["keys"]):
            print(f"이미 진단한 경보라 건너뛴다: {alert['name']}")
            continue
        if not within_daily_limit(alert["env"], alert["channel"]):
            continue
        try:
            result = diagnose(alert["prompt"])
        except Exception as error:
            print(f"진단 실패: {alert['name']}: {error!r}")
            post(alert["channel"], f"*AI 진단 실패: {alert['name']}*\n`{type(error).__name__}`. 런북을 직접 따른다: {alert['runbook_link']}")
            continue
        print(json.dumps({"alert": alert["name"], "usage": result["usage"]}, ensure_ascii=False))
        post(alert["channel"], render(alert, result))


def parse(message):
    if message.get("source") == "grafana":
        firing = message.get("alerts") or []
        if not firing:
            return None
        labels = firing[0].get("labels", {})
        name = labels.get("alertname", "이름 없는 경보")
        runbook = firing[0].get("annotations", {}).get("runbook_url", "")
        details = [
            {
                "labels": a.get("labels", {}),
                "summary": a.get("annotations", {}).get("summary"),
                "runbook_url": a.get("annotations", {}).get("runbook_url"),
                "starts_at": a.get("startsAt"),
                "values": a.get("valueString") or a.get("values"),
            }
            for a in firing
        ]
        env = "prod" if labels.get("env") == "prod" else "dev"
        return build(name, env, env, runbook,
                     [f"grafana#{a.get('fingerprint')}#{a.get('startsAt')}" for a in firing],
                     "Grafana 경보", details)

    if "AlarmName" in message:
        if message.get("NewStateValue") != "ALARM":
            return None
        name = message["AlarmName"]
        details = {k: message.get(k) for k in ("AlarmName", "AlarmDescription", "NewStateReason", "StateChangeTime", "Trigger")}
        prod = name.startswith("prod-")
        return build(name, "prod" if prod else "dev", "prod-aws" if prod else "dev", message.get("AlarmDescription", ""),
                     [f"cloudwatch#{name}#{message.get('StateChangeTime')}"], "CloudWatch 경보", details)

    content = message.get("content") if message.get("source") == "custom" else None
    if content:
        name = content.get("title", "이벤트 알림")
        hour = datetime.datetime.now(KST).strftime("%Y-%m-%dT%H")
        steps = " ".join(content.get("nextSteps", []))
        return build(name, "prod", "prod-aws", steps, [f"event#{name}#{hour}"], "EventBridge 알림", content)

    print("모르는 형식의 알림이라 건너뛴다")
    return None


def build(name, env, channel, runbook_source, keys, kind, details):
    match = RUNBOOK_URL.search(runbook_source or "")
    runbook = match.group(1) if match else None
    link = f"<{match.group(0)}|{runbook}>" if match else "런북 링크 없음"
    prompt = (
        f"{kind}가 울렸다. 환경: {'운영' if env == 'prod' else '개발'}. 런북 파일: {runbook or '알 수 없음'}.\n"
        f"지금 시각(UTC): {datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}\n"
        f"경보 내용(데이터):\n{json.dumps(details, ensure_ascii=False, default=str)[:8000]}"
    )
    return {"name": name, "env": env, "channel": channel, "keys": keys, "runbook_link": link, "prompt": prompt}


def claim(keys):
    expires = int(time.time()) + 7 * 86400
    claimed = False
    for key in keys:
        try:
            _dynamodb.put_item(
                TableName=STATE_TABLE,
                Item={"key": {"S": key}, "expires_at": {"N": str(expires)}},
                ConditionExpression="attribute_not_exists(#k)",
                ExpressionAttributeNames={"#k": "key"},
            )
            claimed = True
        except ClientError as error:
            if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise
    return claimed


def within_daily_limit(env, channel):
    today = datetime.datetime.now(KST).strftime("%Y-%m-%d")
    expires = int(time.time()) + 3 * 86400
    try:
        _dynamodb.update_item(
            TableName=STATE_TABLE,
            Key={"key": {"S": f"day#{env}#{today}"}},
            UpdateExpression="SET #c = if_not_exists(#c, :zero) + :one, expires_at = :exp",
            ConditionExpression="attribute_not_exists(#c) OR #c < :limit",
            ExpressionAttributeNames={"#c": "count"},
            ExpressionAttributeValues={":zero": {"N": "0"}, ":one": {"N": "1"}, ":limit": {"N": str(DAILY_LIMIT)},
                                       ":exp": {"N": str(expires)}},
        )
        return True
    except ClientError as error:
        if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
            raise
    if claim([f"limit-notice#{env}#{today}"]):
        post(channel, f"*AI 진단 하루 상한({DAILY_LIMIT}건)에 닿았다.* 오늘 남은 경보는 진단하지 않으니 런북을 직접 따른다.")
    return False


def render(alert, result):
    usage = result["usage"]
    footer = (
        f"런북: {alert['runbook_link']} · 조회 {usage['tool_calls']}번 · "
        f"토큰 입력 {usage['input'] + usage['cache_read'] + usage['cache_write']:,}(캐시 읽기 {usage['cache_read']:,})·출력 {usage['output']:,} · "
        f"약 ${usage['cost']:.2f}"
    )
    return f"*AI 진단: {alert['name']}* (참고용, 실행은 사람이 판단)\n{result['text']}\n_{footer}_"


def post(channel, text):
    if channel == "prod-aws":
        # Amazon Q는 사용자 지정 알림 형식만 채널에 보여 준다. 본문은 8,000자까지다.
        notification = {"version": "1.0", "source": "custom", "content": {"textType": "client-markdown", "description": text[:8000]}}
        _sns.publish(TopicArn=PROD_CHATBOT_TOPIC, Message=json.dumps(notification, ensure_ascii=False))
        return
    if channel not in _webhooks:
        _webhooks[channel] = _ssm.get_parameter(Name=WEBHOOK_PARAMETERS[channel], WithDecryption=True)["Parameter"]["Value"]
    request = urllib.request.Request(
        _webhooks[channel], data=json.dumps({"text": text}).encode(), headers={"Content-Type": "application/json"}, method="POST",
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        response.read()
