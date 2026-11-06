import base64
import datetime

import pytest

import commands


@pytest.fixture
def clock(monkeypatch):
    now = [1000.0]
    monkeypatch.setattr(commands.time, "time", lambda: now[0])
    monkeypatch.setattr(commands.time, "sleep", lambda s: now.__setitem__(0, now[0] + s))
    return now


def invocation(status, out="", err=""):
    return {"Status": status, "StandardOutputContent": out, "StandardErrorContent": err}


class TestUtcTime:
    def test_naive_is_utc(self):
        assert commands.utc_time("2026-11-05T01:02:03") == datetime.datetime(2026, 11, 5, 1, 2, 3, tzinfo=datetime.timezone.utc)

    def test_offset_converted(self):
        assert commands.utc_time("2026-11-05T10:00:00+09:00").hour == 1

    def test_z_suffix(self):
        assert commands.utc_time("2026-11-05T01:00:00Z").tzinfo == datetime.timezone.utc


class TestRunDocument:
    def test_waits_until_finished(self, clock):
        commands._ssm.send_command.return_value = {"Command": {"CommandId": "c1"}}
        commands._ssm.get_command_invocation.side_effect = [
            commands._ssm.exceptions.InvocationDoesNotExist(), invocation("InProgress"), invocation("Success", "done"),
        ]
        assert commands.run_document("i-1", "doc", {"a": ["b"]}, 60) == ("Success", "done")
        sent = commands._ssm.send_command.call_args.kwargs
        assert sent["TimeoutSeconds"] == 60
        assert sent["InstanceIds"] == ["i-1"]

    def test_minimum_ssm_timeout(self, clock):
        commands._ssm.get_command_invocation.return_value = invocation("Success", "x")
        commands.run_document("i-1", "doc", {}, 10)
        assert commands._ssm.send_command.call_args.kwargs["TimeoutSeconds"] == 30

    def test_stderr_when_no_stdout(self, clock):
        commands._ssm.get_command_invocation.return_value = invocation("Failed", "", "boom")
        assert commands.run_document("i-1", "doc", {}, 60) == ("Failed", "boom")

    def test_times_out(self, clock):
        commands._ssm.get_command_invocation.return_value = invocation("InProgress")
        assert commands.run_document("i-1", "doc", {}, 60) == ("TimedOut", "60초 안에 끝나지 않았다")
        assert clock[0] - 1000 >= 60


class TestObservabilityQuery:
    @pytest.fixture
    def run(self, monkeypatch):
        calls = []

        def fake(instance, document, parameters, timeout):
            calls.append((instance, document, parameters, timeout))
            return "Success", '{"series": []}'

        monkeypatch.setattr(commands, "run_document", fake)
        return calls

    def test_parameters(self, run):
        assert commands.observability_query("loki", '{app="x"}', 60) == '{"series": []}'
        instance, document, parameters, timeout = run[0]
        assert document == commands.QUERY_DOCUMENT
        assert base64.b64decode(parameters["query"][0]).decode() == '{app="x"}'
        assert parameters["minutes"] == ["60"]
        assert "end" not in parameters
        assert timeout == 60

    @pytest.mark.parametrize("minutes,expected", [(0, "1"), (-5, "1"), (20000, "10080")])
    def test_minutes_clamped(self, run, minutes, expected):
        commands.observability_query("prometheus", "up", minutes)
        assert run[0][2]["minutes"] == [expected]

    def test_end_to_epoch(self, run):
        commands.observability_query("prometheus", "up", 1, "2026-11-05T00:00:00Z")
        assert run[0][2]["end"] == [str(int(datetime.datetime(2026, 11, 5, tzinfo=datetime.timezone.utc).timestamp()))]

    def test_status_when_no_output(self, monkeypatch):
        monkeypatch.setattr(commands, "run_document", lambda *a: ("TimedOut", ""))
        assert commands.observability_query("loki", "x", 1) == "TimedOut"
