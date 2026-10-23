"""Slack 승인 버튼 클릭을 받는다(함수 URL). Slack은 3초 안에 응답을 받아야 해 실행은 실행 함수에 맡긴다."""
import base64
import datetime
import hashlib
import hmac
import json
import os
import time
import urllib.parse
import urllib.request

import boto3
from botocore.exceptions import ClientError

import slack

REGION = "ap-northeast-2"
KST = datetime.timezone(datetime.timedelta(hours=9))
STATE_TABLE = os.environ["STATE_TABLE"]
EXECUTOR_FUNCTION = os.environ["EXECUTOR_FUNCTION"]
SIGNING_SECRET_PARAMETER = "/cking/dev/monitoring/SLACK_SIGNING_SECRET"
APPROVERS_PARAMETER = "/cking/dev/monitoring/AI_ACTION_APPROVERS"
SIGNATURE_MAX_AGE = 300

_dynamodb = boto3.client("dynamodb", region_name=REGION)
_lambda = boto3.client("lambda", region_name=REGION)


def _verified(headers, body):
    timestamp = headers.get("x-slack-request-timestamp", "")
    if not timestamp.isdigit() or abs(time.time() - int(timestamp)) > SIGNATURE_MAX_AGE:
        return False
    secret = slack._parameter(SIGNING_SECRET_PARAMETER)
    expected = "v0=" + hmac.new(secret.encode(), f"v0:{timestamp}:{body}".encode(), hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, headers.get("x-slack-signature", ""))


def _ephemeral(response_url, text):
    if not response_url.startswith("https://hooks.slack.com/"):
        return
    request = urllib.request.Request(
        response_url, method="POST", headers={"Content-Type": "application/json"},
        data=json.dumps({"response_type": "ephemeral", "replace_original": False, "text": text}).encode(),
    )
    with urllib.request.urlopen(request, timeout=5) as response:
        response.read()


def handler(event, context):
    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        body = base64.b64decode(body).decode()
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    if not _verified(headers, body):
        return {"statusCode": 401, "body": ""}
    payload = json.loads(urllib.parse.parse_qs(body).get("payload", ["{}"])[0])
    clicked = next((a for a in payload.get("actions", []) if a.get("action_id") == "approve_action"), None)
    if payload.get("type") != "block_actions" or not clicked:
        return {"statusCode": 200, "body": ""}

    user = payload["user"]["id"]
    response_url = payload.get("response_url", "")
    key = {"key": {"S": f"action#{clicked['value']}"}}
    approvers = slack._parameter(APPROVERS_PARAMETER).split(",")
    if user not in approvers:
        _ephemeral(response_url, "승인자 목록에 없어 실행하지 않는다. 런북을 직접 따른다.")
        return {"statusCode": 200, "body": ""}

    now = int(time.time())
    try:
        item = _dynamodb.update_item(
            TableName=STATE_TABLE, Key=key, ReturnValues="ALL_NEW",
            UpdateExpression="SET #s = :approved, approver = :user, approved_at = :now",
            ConditionExpression="#s = :pending AND valid_until > :now",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":approved": {"S": "approved"}, ":pending": {"S": "pending"},
                                       ":user": {"S": user}, ":now": {"N": str(now)}},
        )["Attributes"]
    except ClientError as error:
        if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
            raise
        current = _dynamodb.get_item(TableName=STATE_TABLE, Key=key).get("Item", {})
        status = current.get("status", {}).get("S", "없음")
        reason = "15분이 지나 실행하지 않는다. 런북을 직접 따른다." if status == "pending" else f"이미 처리된 조치다({status})."
        _ephemeral(response_url, reason)
        return {"statusCode": 200, "body": ""}

    _lambda.invoke(FunctionName=EXECUTOR_FUNCTION, InvocationType="Event", Payload=json.dumps({"id": clicked["value"]}))
    title = item["title"]["S"]
    base = json.loads(item["base_blocks"]["S"])
    stamp = datetime.datetime.now(KST).strftime("%H:%M")
    try:
        slack.update(item["channel"]["S"], item["ts"]["S"], f"[AI 조치] {title} 실행 중",
                     base[:-1] + [slack.context(f"승인: <@{user}> {stamp} · {title} 실행 중")] + base[-1:])
    except Exception as error:
        print(f"메시지 갱신 실패: {error!r}")
    return {"statusCode": 200, "body": ""}
