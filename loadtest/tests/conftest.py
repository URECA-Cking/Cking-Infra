import socket
import sys
import urllib.request
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "runner"))

import ltrun  # noqa: E402

TARGET = {
    "base_url": "http://app.test", "param_path": "/cking/loadtest", "results_bucket": "results-bucket",
    "app_name_tag": "loadtest-cking-app", "k6_name_tag": "loadtest-cking-k6", "instance_prefix": "loadtest-cking-",
    "query_instance_name_tag": "dev-cking-observability", "query_document": "query-doc", "query_role_arn": "arn:role",
    "slack_webhook_parameter": "/hook",
}


@pytest.fixture(autouse=True)
def no_network(monkeypatch):
    def refuse(*args, **kwargs):
        raise AssertionError("테스트에서 네트워크를 쓰면 안 된다")

    monkeypatch.setattr(urllib.request, "urlopen", refuse)
    monkeypatch.setattr(socket.socket, "connect", refuse)


@pytest.fixture
def clock(monkeypatch):
    """ltrun의 time.time·sleep을 가짜 시계로 바꾼다. sleep은 시계만 앞으로 돌린다."""
    now = [1_800_000_000.0]
    monkeypatch.setattr(ltrun.time, "time", lambda: now[0])
    monkeypatch.setattr(ltrun.time, "sleep", lambda s: now.__setitem__(0, now[0] + s))
    return now


@pytest.fixture
def runner(tmp_path, monkeypatch):
    monkeypatch.setattr(ltrun, "ROOT", tmp_path)
    scenario = tmp_path / "scenario.toml"
    scenario.write_text('name = "unit"\n\n[[steps]]\ntype = "verify"\n')
    r = ltrun.Runner("loadtest", dict(TARGET), scenario, "run-1", "infra123", "be4567")
    monkeypatch.setattr(r, "upload", lambda: None)
    r.vars["round"] = 1
    yield r
    r.timeline.close()
