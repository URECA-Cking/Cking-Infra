import os
import socket
import sys
import urllib.request
from pathlib import Path
from unittest import mock

import boto3
import pytest
from botocore.exceptions import ClientError

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

os.environ.update({
    "STATE_TABLE": "test-state",
    "EXECUTOR_FUNCTION": "test-executor",
    "SLACK_CHANNELS": '{"dev": "C-DEV", "prod": "C-PROD"}',
    "OBSERVABILITY_INSTANCE_ID": "i-0000000000000000a",
    "DEV_APP_INSTANCE_ID": "i-0000000000000000b",
})


def _fake_client(service, *args, **kwargs):
    client = mock.MagicMock(name=f"{service}-client")
    client.get_parameter.return_value = {"Parameter": {"Value": "test-value"}}
    client.exceptions.InvocationDoesNotExist = type("InvocationDoesNotExist", (Exception,), {})
    return client


# 모듈이 불러올 때 AWS 클라이언트를 만들고 diagnose는 Parameter Store를 읽는다. 진짜 클라이언트가 만들어지지 않게 막는다.
with mock.patch.object(boto3, "client", _fake_client):
    import actions  # noqa: E402,F401
    import approvals  # noqa: E402,F401
    import commands  # noqa: E402,F401
    import diagnose  # noqa: E402,F401
    import executor  # noqa: E402,F401
    import handler  # noqa: E402,F401
    import slack  # noqa: E402,F401
    import tools  # noqa: E402,F401


@pytest.fixture
def client_error():
    def make(code="ConditionalCheckFailedException"):
        return ClientError({"Error": {"Code": code, "Message": code}}, "Op")
    return make


@pytest.fixture(autouse=True)
def no_network(monkeypatch):
    def refuse(*args, **kwargs):
        raise AssertionError("테스트에서 네트워크를 쓰면 안 된다")

    monkeypatch.setattr(urllib.request, "urlopen", refuse)
    monkeypatch.setattr(socket.socket, "connect", refuse)


@pytest.fixture(autouse=True)
def fresh_clients(monkeypatch):
    for module in (actions, approvals, commands, executor, handler, slack, tools):
        for name in dir(module):
            if name.startswith("_") and isinstance(getattr(module, name), mock.MagicMock):
                monkeypatch.setattr(module, name, _fake_client(name))
    monkeypatch.setattr(slack, "_cache", {})
    tools.PROPOSAL.clear()


@pytest.fixture
def slack_calls(monkeypatch):
    """slack.post·update를 기록만 하는 가짜로 바꾼다. post는 (채널, ts)를 돌려준다."""
    calls = {"post": [], "update": []}

    def post(env, text, blocks=None, thread_ts=None):
        calls["post"].append({"env": env, "text": text, "blocks": blocks, "thread_ts": thread_ts})
        return calls.get("post_return", ("C-DEV", "111.222"))

    def update(channel, ts, text, blocks):
        calls["update"].append({"channel": channel, "ts": ts, "text": text, "blocks": blocks})

    monkeypatch.setattr(slack, "post", post)
    monkeypatch.setattr(slack, "update", update)
    return calls
