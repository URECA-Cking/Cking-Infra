import datetime
import json
import os
import re
import time
import uuid

import boto3
from botocore.exceptions import ClientError

import slack
from diagnose import diagnose

REGION = "ap-northeast-2"
KST = datetime.timezone(datetime.timedelta(hours=9))
STATE_TABLE = os.environ["STATE_TABLE"]
DAILY_LIMIT = int(os.environ.get("DAILY_LIMIT", "12"))
ACTION_VALID_SECONDS = 15 * 60
ACTION_NEEDED = re.compile(r"^\*판단\*:\s*지금 조치 필요")
ENV_LABELS = {"dev": "개발", "prod": "운영"}
RUNBOOK_URL = re.compile(r"https://github\.com/URECA-Cking/Cking-Infra/blob/main/docs/runbooks/([A-Za-z0-9-]+)\.md")

_dynamodb = boto3.client("dynamodb", region_name=REGION)


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
        if not within_daily_limit(alert["env"]):
            continue
        try:
            result = diagnose(alert["prompt"])
        except Exception as error:
            print(f"진단 실패: {alert['name']}: {error!r}")
            slack.post(alert["env"], f"*[AI 진단 실패] {alert['name']}* · {ENV_LABELS[alert['env']]}\n`{type(error).__name__}`. 런북을 직접 따른다: {alert['runbook_link']}")
            continue
        print(json.dumps({"alert": alert["name"], "usage": result["usage"], "proposal": result["proposal"]}, ensure_ascii=False))
        publish(alert, result)


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
        return build(name, "prod" if labels.get("env") == "prod" else "dev", runbook,
                     [f"grafana#{a.get('fingerprint')}#{a.get('startsAt')}" for a in firing],
                     "Grafana 경보", details)

    if "AlarmName" in message:
        if message.get("NewStateValue") != "ALARM":
            return None
        name = message["AlarmName"]
        details = {k: message.get(k) for k in ("AlarmName", "AlarmDescription", "NewStateReason", "StateChangeTime", "Trigger")}
        return build(name, "prod" if name.startswith("prod-") else "dev", message.get("AlarmDescription", ""),
                     [f"cloudwatch#{name}#{message.get('StateChangeTime')}"], "CloudWatch 경보", details)

    content = message.get("content") if message.get("source") == "custom" else None
    if content:
        name = content.get("title", "이벤트 알림")
        hour = datetime.datetime.now(KST).strftime("%Y-%m-%dT%H")
        steps = " ".join(content.get("nextSteps", []))
        return build(name, "prod", steps, [f"event#{name}#{hour}"], "EventBridge 알림", content)

    print("모르는 형식의 알림이라 건너뛴다")
    return None


def build(name, env, runbook_source, keys, kind, details):
    match = RUNBOOK_URL.search(runbook_source or "")
    runbook = match.group(1) if match else None
    link = f"<{match.group(0)}|{runbook}>" if match else "런북 링크 없음"
    prompt = (
        f"{kind}가 울렸다. 환경: {'운영' if env == 'prod' else '개발'}. 런북 파일: {runbook or '알 수 없음'}.\n"
        f"지금 시각(UTC): {datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}\n"
        f"경보 내용(데이터):\n{json.dumps(details, ensure_ascii=False, default=str)[:8000]}"
    )
    return {"name": name, "env": env, "keys": keys, "runbook_link": link, "prompt": prompt}


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


def within_daily_limit(env):
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
        slack.post(env, f"*[AI 진단] 하루 상한({DAILY_LIMIT}건)에 닿았다* · {ENV_LABELS[env]}\n오늘 남은 경보는 진단하지 않는다. 런북을 직접 따른다.")
    return False


def render(alert, result):
    """(웹훅용 글자, 버튼을 뺀 블록)을 돌려준다."""
    usage = result["usage"]
    head = f"*[AI 진단] {alert['name']}* · {ENV_LABELS[alert['env']]} · 참고용\n{result['text']}"
    foot = f"런북: {alert['runbook_link']} · 조회 {usage['tool_calls']}번 · ${usage['cost']:.2f}"
    return f"{head}\n_{foot}_", slack.sections(head) + [slack.context(foot)]


def button(record_id, title, impact):
    return {"type": "actions", "block_id": "ai_action", "elements": [{
        "type": "button", "action_id": "approve_action", "style": "danger", "value": record_id,
        "text": {"type": "plain_text", "text": f"승인하고 실행: {title}"[:75]},
        "confirm": {
            "title": {"type": "plain_text", "text": "조치 실행 확인"},
            "text": {"type": "mrkdwn", "text": impact[:300]},
            "confirm": {"type": "plain_text", "text": "실행"},
            "deny": {"type": "plain_text", "text": "취소"},
        },
    }]}


def publish(alert, result):
    text, blocks = render(alert, result)
    proposal = result.get("proposal")
    if not proposal or not ACTION_NEEDED.match(result["text"]):
        slack.post(alert["env"], text, blocks)
        return
    if not proposal["ok"]:
        blocks.append(slack.context(f"조치 버튼 없음({proposal['title']}): {proposal['note']}"))
        slack.post(alert["env"], text, blocks)
        return
    record_id = uuid.uuid4().hex
    now = int(time.time())
    _dynamodb.put_item(TableName=STATE_TABLE, Item={
        "key": {"S": f"action#{record_id}"},
        "action": {"S": proposal["action"]},
        "params": {"S": json.dumps(proposal["params"], ensure_ascii=False)},
        "title": {"S": proposal["title"]},
        "env": {"S": alert["env"]},
        "alert": {"S": alert["name"]},
        "base_blocks": {"S": json.dumps(blocks, ensure_ascii=False)},
        "status": {"S": "pending"},
        "valid_until": {"N": str(now + ACTION_VALID_SECONDS)},
        "expires_at": {"N": str(now + 7 * 86400)},
    })
    note = slack.context("승인자만 누를 수 있다. 15분이 지나면 실행하지 않는다.")
    channel, ts = slack.post(alert["env"], text, blocks[:-1] + [button(record_id, proposal["title"], proposal["note"]), note, blocks[-1]])
    if channel:
        _dynamodb.update_item(
            TableName=STATE_TABLE, Key={"key": {"S": f"action#{record_id}"}},
            UpdateExpression="SET #c = :c, #t = :t", ExpressionAttributeNames={"#c": "channel", "#t": "ts"},
            ExpressionAttributeValues={":c": {"S": channel}, ":t": {"S": ts}},
        )
