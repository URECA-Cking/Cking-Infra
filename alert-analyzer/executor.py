"""승인된 조치를 실행하고 결과를 원래 메시지 스레드에 남긴다."""
import datetime
import json
import os
import time

import boto3
from botocore.exceptions import ClientError

import actions
import slack

REGION = "ap-northeast-2"
KST = datetime.timezone(datetime.timedelta(hours=9))
STATE_TABLE = os.environ["STATE_TABLE"]

_dynamodb = boto3.client("dynamodb", region_name=REGION)


def _set(key, values):
    names = {f"#{k}": k for k in values}
    _dynamodb.update_item(
        TableName=STATE_TABLE, Key=key,
        UpdateExpression="SET " + ", ".join(f"#{k} = :{k}" for k in values),
        ExpressionAttributeNames=names,
        ExpressionAttributeValues={f":{k}": v for k, v in values.items()},
    )


def handler(event, context):
    key = {"key": {"S": f"action#{event['id']}"}}
    try:
        item = _dynamodb.update_item(
            TableName=STATE_TABLE, Key=key, ReturnValues="ALL_NEW",
            UpdateExpression="SET #s = :running", ConditionExpression="#s = :approved",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":running": {"S": "running"}, ":approved": {"S": "approved"}},
        )["Attributes"]
    except ClientError as error:
        if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
            print(f"승인 상태가 아니라 실행하지 않는다: {event['id']}")
            return
        raise

    action, title, env = item["action"]["S"], item["title"]["S"], item["env"]["S"]
    approver = item["approver"]["S"]
    started = time.time()
    try:
        ok, result = actions.run(action, json.loads(item["params"]["S"]))
    except Exception as error:
        ok, result = False, f"실패: `{type(error).__name__}` {str(error)[:500]}"
    elapsed = int(time.time() - started)
    _set(key, {"status": {"S": "done" if ok else "failed"}, "result": {"S": result[:3000]},
               "finished_at": {"N": str(int(time.time()))}})
    print(json.dumps({"action": action, "title": title, "approver": approver, "ok": ok, "elapsed": elapsed}, ensure_ascii=False))

    mark = "실행함" if ok else "실행하지 못함"
    channel, ts = item.get("channel", {}).get("S"), item.get("ts", {}).get("S")
    slack.post(env, f"*[AI 조치] {title}* · {actions.ENV_LABELS[env]} · {mark}\n승인: <@{approver}> · {elapsed}초\n{result}", thread_ts=ts)
    if channel and ts:
        base = json.loads(item["base_blocks"]["S"])
        stamp = datetime.datetime.now(KST).strftime("%H:%M")
        try:
            slack.update(channel, ts, f"[AI 조치] {title} {mark}",
                         base[:-1] + [slack.context(f"{mark}: <@{approver}> {stamp} · {title} · 결과는 스레드")] + base[-1:])
        except Exception as error:
            print(f"메시지 갱신 실패: {error!r}")
