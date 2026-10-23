import json
import os
import urllib.request

import boto3

REGION = "ap-northeast-2"
BOT_TOKEN_PARAMETER = "/cking/dev/monitoring/SLACK_BOT_TOKEN"
WEBHOOK_PARAMETERS = {
    "dev": "/cking/dev/monitoring/SLACK_ALERT_WEBHOOK_URL",
    "prod": "/cking/dev/monitoring/SLACK_PROD_ALERT_WEBHOOK_URL",
}
CHANNELS = json.loads(os.environ.get("SLACK_CHANNELS", "{}"))
SECTION_CHARS = 2900

_ssm = boto3.client("ssm", region_name=REGION)
_cache = {}


def _parameter(name):
    if name not in _cache:
        _cache[name] = _ssm.get_parameter(Name=name, WithDecryption=True)["Parameter"]["Value"]
    return _cache[name]


def _request(url, payload, headers):
    request = urllib.request.Request(url, data=json.dumps(payload).encode(), headers=headers, method="POST")
    with urllib.request.urlopen(request, timeout=10) as response:
        return response.read()


def api(method, payload):
    body = json.loads(_request(
        f"https://slack.com/api/{method}", payload,
        {"Content-Type": "application/json; charset=utf-8", "Authorization": f"Bearer {_parameter(BOT_TOKEN_PARAMETER)}"},
    ))
    if not body.get("ok"):
        raise RuntimeError(f"Slack {method}: {body.get('error')}")
    return body


def sections(text):
    blocks, chunk = [], ""
    for line in text.split("\n"):
        if chunk and len(chunk) + len(line) + 1 > SECTION_CHARS:
            blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": chunk}})
            chunk = ""
        chunk = f"{chunk}\n{line}" if chunk else line[:SECTION_CHARS]
    if chunk:
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": chunk}})
    return blocks


def context(text):
    return {"type": "context", "elements": [{"type": "mrkdwn", "text": text[:2900]}]}


def post(env, text, blocks=None, thread_ts=None):
    """봇으로 게시하고 (채널, ts)를 돌려준다. 봇 게시가 안 되면 웹훅으로 글자만 보내고 (None, None)."""
    try:
        payload = {"channel": CHANNELS[env], "text": text.split("\n")[0][:150], "blocks": blocks or sections(text)}
        if thread_ts:
            payload["thread_ts"] = thread_ts
        body = api("chat.postMessage", payload)
        return body["channel"], body["ts"]
    except Exception as error:
        print(f"봇 게시 실패, 웹훅으로 보낸다: {error!r}")
        _request(_parameter(WEBHOOK_PARAMETERS[env]), {"text": text}, {"Content-Type": "application/json"})
        return None, None


def update(channel, ts, text, blocks):
    api("chat.update", {"channel": channel, "ts": ts, "text": text.split("\n")[0][:150], "blocks": blocks})
