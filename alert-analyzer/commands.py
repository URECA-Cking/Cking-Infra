import base64
import datetime
import os
import time

import boto3

REGION = "ap-northeast-2"
OBSERVABILITY_INSTANCE = os.environ.get("OBSERVABILITY_INSTANCE_ID", "")
QUERY_DOCUMENT = os.environ.get("QUERY_DOCUMENT", "dev-cking-observability-query")

_ssm = boto3.client("ssm", region_name=REGION)


def utc_time(value):
    parsed = datetime.datetime.fromisoformat(value)
    return parsed.replace(tzinfo=datetime.timezone.utc) if parsed.tzinfo is None else parsed.astimezone(datetime.timezone.utc)


def run_document(instance_id, document, parameters, timeout):
    """SSM 문서를 서버 하나에 실행하고 끝날 때까지 기다려 (상태, 출력)을 돌려준다."""
    command = _ssm.send_command(
        InstanceIds=[instance_id], DocumentName=document, Parameters=parameters, TimeoutSeconds=max(30, timeout),
    )["Command"]["CommandId"]
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(1 if timeout <= 60 else 3)
        try:
            result = _ssm.get_command_invocation(CommandId=command, InstanceId=instance_id)
        except _ssm.exceptions.InvocationDoesNotExist:
            continue
        if result["Status"] in ("Pending", "InProgress", "Delayed"):
            continue
        return result["Status"], result["StandardOutputContent"] or result["StandardErrorContent"]
    return "TimedOut", f"{timeout}초 안에 끝나지 않았다"


def observability_query(kind, query, minutes, end=""):
    parameters = {
        "kind": [kind],
        "query": [base64.b64encode(query.encode()).decode()],
        "minutes": [str(max(1, min(minutes, 10080)))],
    }
    if end:
        parameters["end"] = [str(int(utc_time(end).timestamp()))]
    status, output = run_document(OBSERVABILITY_INSTANCE, QUERY_DOCUMENT, parameters, 60)
    return output or status
