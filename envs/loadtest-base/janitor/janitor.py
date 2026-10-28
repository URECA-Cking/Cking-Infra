"""부하 테스트 리소스 정리기. 1시간마다 cking:ttl-hours 태그가 있는 EC2·RDS 중 켜진 지 그 시간이 지난 것을 멈춘다.

지우지 않고 멈춘다. Terraform state와 어긋나지 않고, 다시 켜거나 terraform destroy로 지울 수 있다. 멈춘 것은 Slack으로 알린다.
"""
import datetime
import json
import os
import urllib.request

import boto3

TAG = "cking:ttl-hours"
ec2 = boto3.client("ec2")
rds = boto3.client("rds")
ssm = boto3.client("ssm")


def expired(started, tags):
    hours = float(tags.get(TAG, "0") or 0)
    age = datetime.datetime.now(datetime.timezone.utc) - started
    return hours > 0 and age > datetime.timedelta(hours=hours), age


def handler(event, context):
    stopped = []
    pages = ec2.get_paginator("describe_instances").paginate(
        Filters=[{"Name": "tag-key", "Values": [TAG]}, {"Name": "instance-state-name", "Values": ["running"]}])
    for page in pages:
        for r in page["Reservations"]:
            for i in r["Instances"]:
                tags = {t["Key"]: t["Value"] for t in i.get("Tags", [])}
                over, age = expired(i["LaunchTime"], tags)
                if over:
                    ec2.stop_instances(InstanceIds=[i["InstanceId"]])
                    stopped.append(f"EC2 {tags.get('Name', i['InstanceId'])} ({age.total_seconds() / 3600:.1f}시간)")
    for db in rds.describe_db_instances()["DBInstances"]:
        if db["DBInstanceStatus"] != "available":
            continue
        tags = {t["Key"]: t["Value"] for t in db.get("TagList", [])}
        over, age = expired(db["InstanceCreateTime"], tags)
        if over:
            rds.stop_db_instance(DBInstanceIdentifier=db["DBInstanceIdentifier"])
            stopped.append(f"RDS {db['DBInstanceIdentifier']} ({age.total_seconds() / 3600:.1f}시간)")
    if stopped:
        notify("부하 테스트 리소스가 만료 시간을 넘겨 멈춤: " + ", ".join(stopped)
               + ". 다 썼으면 envs/loadtest에서 terraform destroy")
    print(json.dumps({"stopped": stopped}, ensure_ascii=False))
    return {"stopped": stopped}


def notify(text):
    url = ssm.get_parameter(Name=os.environ["SLACK_WEBHOOK_PARAMETER"], WithDecryption=True)["Parameter"]["Value"]
    body = json.dumps({"text": text}).encode()
    urllib.request.urlopen(urllib.request.Request(url, body, {"Content-Type": "application/json"}), timeout=10).read()
