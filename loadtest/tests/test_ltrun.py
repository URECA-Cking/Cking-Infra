import json
import tomllib
from pathlib import Path

import pytest

import ltrun

SCENARIOS = sorted((Path(__file__).resolve().parent.parent / "scenarios").glob("*.toml"))
XINFO = "name\nentries-consumer\nconsumers\n2\npending\n{p1}\nlast-delivered-id\n1-0\nentries-read\n10\nlag\n{l1}\n" \
        "name\nother\nconsumers\n1\npending\n{p2}\nlast-delivered-id\n1-0\nentries-read\n10\nlag\n{l2}\n"
VERIFY_DONE = "PASS  잔액 대조\nPASS  원장\n== 결과: PASS 2 / FAIL 0\n"


def entry(sent, latency, code="SUCCESS", event=1, **extra):
    return json.dumps({"kind": "entry", "sentAt": sent, "at": sent + latency, "code": code, "eventId": event, **extra})


class TestHelpers:
    @pytest.mark.parametrize("value,expected", [(90, 90.0), (1.5, 1.5), ("90", 90.0), ("90s", 90.0), ("5m", 300.0), ("1h", 3600.0), (" 2.5m ", 150.0)])
    def test_seconds(self, value, expected):
        assert ltrun.seconds(value) == expected

    @pytest.mark.parametrize("value", ["", "5 m", "1d", "-5", "m"])
    def test_seconds_invalid(self, value):
        with pytest.raises(ValueError):
            ltrun.seconds(value)

    @pytest.mark.parametrize("sec,expected", [(0, "0m00s"), (59.6, "1m00s"), (3599, "59m59s"), (3600, "1h00m00s"), (7322, "2h02m02s")])
    def test_span(self, sec, expected):
        assert ltrun.span(sec) == expected

    def test_fill_keeps_shell_braces(self):
        text = "id={closing_event_id} ${HOME} awk '{print $1}' {unknown}"
        assert ltrun.fill(text, {"closing_event_id": 7}) == "id=7 ${HOME} awk '{print $1}' {unknown}"

    def test_parse(self):
        assert ltrun.parse('{"a": 1}') == {"a": 1}
        assert ltrun.parse("time=... level=info") is None
        assert ltrun.parse("{broken") is None


class TestCheckScenario:
    @pytest.mark.parametrize("path", SCENARIOS, ids=lambda p: p.name)
    def test_repo_scenarios_valid(self, path):
        assert ltrun.check_scenario(tomllib.loads(path.read_text())) == []

    @pytest.mark.parametrize("doc,error", [
        ({}, "steps가 없다"),
        ({"steps": []}, "steps가 없다"),
        ({"stepz": [], "steps": [{"type": "verify"}]}, "알 수 없는 항목: stepz"),
        ({"seed": {"member": 1}, "steps": [{"type": "verify"}]}, "seed: 알 수 없는 항목 member"),
        ({"steps": [{"type": "sleep"}]}, "steps[1] sleep: 알 수 없는 단계"),
        ({"steps": [{"type": "drain", "timeout": "5m", "seconds": 3}]}, "steps[1] drain: 알 수 없는 항목 seconds"),
        ({"steps": [{"type": "k6", "name": "a"}]}, "steps[1] k6: name·script 필요"),
        ({"steps": [{"type": "k6", "name": "a", "script": "x.js"}, {"type": "k6", "name": "a", "script": "y.js"}]}, "steps[2] k6: 이름 중복 a"),
        ({"steps": [{"type": "k6", "name": "a", "script": "x.js", "hooks": [{"on": "db", "run": "x", "after": "1m"}]}]},
         "steps[1] k6: 훅은 after·on(app/apps/k6)·run 필요"),
        ({"steps": [{"type": "k6", "name": "a", "script": "x.js", "hooks": [{"on": "app", "run": "x"}]}]},
         "steps[1] k6: 훅은 after·on(app/apps/k6)·run 필요"),
        ({"steps": [{"type": "k6", "name": "a", "script": "x.js", "stop_when": {"p99_ms": 1}}]}, "steps[1] k6: stop_when 알 수 없는 항목 p99_ms"),
        ({"steps": [{"type": "wait"}]}, "steps[1] wait: 기다릴 기준을 하나만 적는다 []"),
        ({"steps": [{"type": "wait", "seconds": 1, "until_utc": "01:00"}]}, "steps[1] wait: 기다릴 기준을 하나만 적는다 ['seconds', 'until_utc']"),
        ({"steps": [{"type": "exec", "on": "app"}]}, "steps[1] exec: on·run 필요"),
        ({"steps": [{"type": "drain", "timeout": "10x"}]}, "steps[1] drain: 시간 형식: 10x (예: 90, 90s, 5m, 1h)"),
    ])
    def test_errors(self, doc, error):
        assert error in ltrun.check_scenario(doc)

    def test_main_check(self, tmp_path, capsys, monkeypatch):
        bad = tmp_path / "bad.toml"
        bad.write_text('[[steps]]\ntype = "nope"\n')
        monkeypatch.setattr("sys.argv", ["ltrun.py", "check", str(SCENARIOS[0]), str(bad)])
        assert ltrun.main() == 1
        assert capsys.readouterr().out == f"{bad}: steps[1] nope: 알 수 없는 단계\n"
        monkeypatch.setattr("sys.argv", ["ltrun.py", "check", *map(str, SCENARIOS)])
        assert ltrun.main() == 0


class TestEntryStats:
    def test_stats(self, tmp_path):
        log = tmp_path / "k6.log"
        lines = [entry(1000 + i * 100, i + 1) for i in range(100)]
        lines += ["not json", json.dumps({"kind": "other"}), entry(20_000, 500, code="INSUFFICIENT_BALANCE")]
        log.write_text("\n".join(lines) + "\n")
        stats = ltrun.entry_stats(log)
        assert stats["n"] == 101
        assert stats["p50"] == 51
        assert stats["p95"] == 96
        assert stats["p99"] == 100
        assert stats["max"] == 500
        assert stats["fail"] == 1
        assert stats["codes"] == {"SUCCESS": 100, "INSUFFICIENT_BALANCE": 1}
        assert stats["rps"] == round(101 / 19.0, 1)

    def test_missing_file(self, tmp_path):
        assert ltrun.entry_stats(tmp_path / "none.log") == {"n": 0, "rps": 0, "p50": None, "p95": None, "p99": None,
                                                           "max": None, "fail": 0, "codes": {}}

    def test_short_run_rps_floor(self, tmp_path):
        log = tmp_path / "k6.log"
        log.write_text(entry(1000, 1) + "\n" + entry(1200, 1) + "\n")
        assert ltrun.entry_stats(log)["rps"] == 2.0


class TestK6Summary:
    def test_summary_export_format(self, tmp_path):
        path = tmp_path / "s.json"
        path.write_text(json.dumps({"metrics": {"http_req_duration": {"p(95)": 123.456}, "http_reqs": {"count": 10},
                                                "http_req_failed": {"value": 0.1}, "dropped_iterations": {"count": 3}}}))
        assert ltrun.k6_summary(path) == {"p95": 123.5, "reqs": 10, "failed_rate": 0.1, "dropped": 3}

    def test_values_format(self, tmp_path):
        path = tmp_path / "s.json"
        path.write_text(json.dumps({"metrics": {"http_req_duration": {"values": {"p(95)": 5}}, "http_req_failed": {"values": {"rate": 0.0}}}}))
        assert ltrun.k6_summary(path) == {"p95": 5, "reqs": None, "failed_rate": 0.0, "dropped": 0}

    @pytest.mark.parametrize("content", [None, "{broken"])
    def test_missing_or_broken(self, tmp_path, content):
        path = tmp_path / "s.json"
        if content is not None:
            path.write_text(content)
        assert ltrun.k6_summary(path) == {}


class TestEntryWindow:
    def test_reads_incrementally_and_drops_old(self, tmp_path, clock):
        log = tmp_path / "k6.log"
        now_ms = clock[0] * 1000
        window = ltrun.EntryWindow(log, 30)
        assert window.read() == {"n": 0, "rps": 0.0, "p95": None, "fail": 0, "codes": {}}

        log.write_text(entry(now_ms - 60_000, 5) + "\n" + entry(now_ms - 1000, 10) + "\n" + entry(now_ms - 900, 20, code="ERR")[:20])
        s = window.read()
        assert (s["n"], s["p95"], s["fail"]) == (1, 10, 0)

        with open(log, "a") as f:
            f.write(entry(now_ms - 900, 20, code="ERR")[20:] + "\n")
        s = window.read()
        assert (s["n"], s["p95"], s["fail"], s["codes"]) == (2, 20, 1, {"SUCCESS": 1, "ERR": 1})
        assert s["rps"] == pytest.approx(2 / 30)


class TestStream:
    """#259: Redis 오류 응답을 밀린 메시지 0으로 보지 않는다."""

    @pytest.fixture
    def reply(self, runner, monkeypatch):
        box = {}

        def app(cmd, *args, **kwargs):
            assert (cmd, args) == ("redis", ("XINFO", "GROUPS", "stream:ticket-deducted"))
            if isinstance(box["out"], Exception):
                raise box["out"]
            return box["out"]

        monkeypatch.setattr(runner, "app", app)
        return box

    def test_sums_groups(self, runner, reply):
        reply["out"] = XINFO.format(p1=3, l1=10, p2=2, l2=0)
        assert runner.stream() == (5, 10)

    @pytest.mark.parametrize("tail", ["lag\n\n", "lag\n", "lag"])
    def test_nil_lag_is_unknown(self, runner, reply, tail):
        """전달 전 메시지가 지워지면 lag를 셀 수 없어 redis-cli·valkey-cli가 빈 줄로 낸다. 밀린 메시지가 있을 수 있으니 0으로 보지 않는다."""
        reply["out"] = "name\ng\nconsumers\n1\npending\n0\nlast-delivered-id\n1-0\nentries-read\n\n" + tail
        assert runner.stream() == (0, None)

    def test_nil_lag_in_one_group_is_unknown(self, runner, reply):
        reply["out"] = XINFO.format(p1=3, l1="", p2=2, l2=0)
        assert runner.stream() == (5, None)

    def test_no_stream_yet(self, runner, reply):
        reply["out"] = "ERR no such key\n"
        assert runner.stream() == (0, 0)

    @pytest.mark.parametrize("out", [
        "NOAUTH Authentication required.\n",
        "NOPERM User app has no permissions to run the 'xinfo|groups' command\n",
        "WRONGTYPE Operation against a key holding the wrong kind of value\n",
        "Could not connect to Redis at 127.0.0.1:6379: Connection refused\n",
        "\n",
    ])
    def test_error_reply_is_unknown(self, runner, reply, out):
        reply["out"] = out
        assert runner.stream() == (None, None)

    def test_command_failure_is_unknown(self, runner, reply):
        reply["out"] = RuntimeError("앱 서버 redis 실패(Failed)")
        assert runner.stream() == (None, None)


class TestDrain:
    @pytest.fixture
    def stream(self, runner, monkeypatch):
        replies = []
        monkeypatch.setattr(runner, "stream", lambda: replies.pop(0) if len(replies) > 1 else replies[0])
        return replies

    def test_done_after_two_zero_reads(self, runner, stream, clock):
        stream.extend([(5, 5), (0, 0), (0, 0)])
        assert runner.step_drain({}).startswith("밀린 메시지 0 (")

    def test_zero_must_hold(self, runner, stream, clock):
        stream.extend([(0, 0), (1, 0), (0, 0), (0, 0)])
        start = clock[0]
        runner.step_drain({})
        assert clock[0] - start == 45

    def test_redis_error_is_not_drained(self, runner, monkeypatch, clock):
        """#259: NOAUTH 같은 오류 응답이 이어지면 끝난 것으로 보지 않고 기한에 실패한다."""
        monkeypatch.setattr(runner, "app", lambda *a, **k: "NOAUTH Authentication required.\n")
        with pytest.raises(RuntimeError, match="pending=None lag=None"):
            runner.step_drain({"timeout": "1m"})

    def test_nil_lag_waits_until_read(self, runner, stream, clock):
        stream.extend([(0, None), (0, 0), (0, 0)])
        start = clock[0]
        runner.step_drain({})
        assert clock[0] - start == 30

    def test_unknown_never_done(self, runner, stream, clock):
        """#259: 읽지 못한 상태(None)가 이어지면 기한에 실패한다."""
        stream.append((None, None))
        with pytest.raises(RuntimeError, match="밀린 메시지가 빠지지 않음 pending=None lag=None"):
            runner.step_drain({"timeout": "1m"})


class TestVerify:
    """#259: verify 실패와 끝나지 않은 출력을 성공으로 보지 않는다."""

    @pytest.fixture
    def app(self, runner, monkeypatch):
        state = {"verify": VERIFY_DONE, "db": "1\t2\n"}

        def app(cmd, *args, **kwargs):
            if cmd == "verify":
                assert kwargs["check"] is False
                return state["verify"]
            assert cmd == "sql"
            return state["db"]

        monkeypatch.setattr(runner, "app", app)
        return state

    def k6_log(self, runner, *lines, name="sustain"):
        (runner.dir / "k6" / f"r1-{name}.log").write_text("\n".join(lines) + "\n")

    def test_all_pass(self, runner, app):
        self.k6_log(runner, entry(1, 1), entry(2, 1), entry(3, 1, code="DUPLICATE"))
        result = runner.step_verify({})
        assert result["text"] == "PASS 3 / FAIL 0"
        assert result["verify"][-1].startswith("PASS  k6 성공 = DB 응모(이벤트별)")
        saved = (runner.dir / "r1-verify.txt").read_text()
        assert saved.startswith(VERIFY_DONE)

    def test_verify_fail_line(self, runner, app):
        app["verify"] = "PASS  잔액 대조\nFAIL  원장 불일치 3건\n== 결과: PASS 1 / FAIL 1\n"
        self.k6_log(runner, entry(1, 1), entry(2, 1))
        with pytest.raises(RuntimeError, match=r"^PASS 2 / FAIL 1$"):
            runner.step_verify({})

    def test_incomplete_output(self, runner, app):
        app["verify"] = "PASS  잔액 대조\n"
        self.k6_log(runner, entry(1, 1), entry(2, 1))
        with pytest.raises(RuntimeError, match="verify 출력이 끝나지 않음"):
            runner.step_verify({})

    def test_k6_db_mismatch(self, runner, app):
        self.k6_log(runner, entry(1, 1))
        with pytest.raises(RuntimeError, match="FAIL 1"):
            runner.step_verify({})
        assert "FAIL  k6 성공 = DB 응모(이벤트별)  k6 {1: 1} DB {1: 2}" in (runner.dir / "r1-verify.txt").read_text()

    def test_other_round_logs_ignored(self, runner, app):
        self.k6_log(runner, entry(1, 1), entry(2, 1))
        (runner.dir / "k6" / "r2-sustain.log").write_text(entry(3, 1) + "\n")
        assert runner.step_verify({})["text"] == "PASS 3 / FAIL 0"

    def test_success_after_closing(self, runner, app):
        runner.vars.update(closing_event_id=1, end_at_ms=10_000)
        self.k6_log(runner, entry(10_500, 1), entry(11_001, 1))
        with pytest.raises(RuntimeError, match="FAIL 1"):
            runner.step_verify({})
        assert "FAIL  마감 1초 뒤 성공 0건  1건" in (runner.dir / "r1-verify.txt").read_text()

    def test_race_rounds(self, runner, app):
        runner.vars["race_balance"] = 3
        app["db"] = "1\t3\n"
        race = [entry(1, 1, phase="race_same", round=1), entry(2, 1, code="DUPLICATE_REPLAY", phase="race_same", round=1),
                entry(3, 1, phase="race_over", round=1), entry(4, 1, phase="race_over", round=1),
                entry(5, 1, code="INSUFFICIENT_BALANCE", phase="race_over", round=1)]
        self.k6_log(runner, *race, name="race")
        assert "PASS  동시 요청 라운드 판정  실패 라운드 0/2" in runner.step_verify({})["verify"]

    def test_race_round_wrong(self, runner, app):
        runner.vars["race_balance"] = 3
        app["db"] = "1\t2\n"
        race = [entry(1, 1, phase="race_same", round=1), entry(2, 1, phase="race_same", round=1)]
        self.k6_log(runner, *race, name="race")
        with pytest.raises(RuntimeError, match="FAIL 1"):
            runner.step_verify({})


class TestSsm:
    @pytest.fixture
    def aws(self, runner, monkeypatch):
        calls = []
        replies = {}

        def aws(*args, check=True, timeout=120, env=None):
            calls.append(args)
            if args[1] == "send-command":
                return "cmd-1"
            reply = replies.get(args[args.index("--instance-id") + 1], [None])
            return reply.pop(0) if len(reply) > 1 else reply[0]

        monkeypatch.setattr(runner, "aws", aws)
        return calls, replies

    def test_collects_each_instance(self, runner, aws, clock):
        calls, replies = aws
        replies["i-1"] = [None, {"Status": "InProgress"}, {"Status": "Success", "StandardOutputContent": "o", "StandardErrorContent": ""}]
        replies["i-2"] = [{"Status": "Failed", "StandardOutputContent": "", "StandardErrorContent": "e"}]
        assert runner.ssm(["i-1", "i-2"], ["echo"], timeout=60) == {"i-1": ("Success", "o", ""), "i-2": ("Failed", "", "e")}
        assert calls[0][:2] == ("ssm", "send-command")

    def test_parameters_file_removed(self, runner, aws, clock):
        calls, replies = aws
        replies["i-1"] = [{"Status": "Success", "StandardOutputContent": "", "StandardErrorContent": ""}]
        runner.ssm(["i-1"], ["echo"], timeout=60)
        path = calls[0][calls[0].index("--parameters") + 1].removeprefix("file://")
        assert not Path(path).exists()

    @pytest.mark.parametrize("stuck", [None, {"Status": "InProgress"}])
    def test_gives_up_after_deadline(self, runner, aws, clock, stuck):
        """상태를 계속 못 읽거나 끝나지 않으면 실행 제한 + 2분에 실패한다(lt.sh ssm과 같은 기준)."""
        _, replies = aws
        replies["i-1"] = [stuck]
        start = clock[0]
        with pytest.raises(RuntimeError, match="SSM 명령 시간 초과 i-1 cmd-1"):
            runner.ssm(["i-1"], ["echo"], timeout=60)
        assert 180 < clock[0] - start <= 184


class TestApp:
    def test_failure_raises(self, runner, monkeypatch):
        runner.fetch_app = ""
        monkeypatch.setattr(runner, "apps", lambda: ["i-1"])
        monkeypatch.setattr(runner, "ssm", lambda ids, commands, timeout: {"i-1": ("Failed", "out", "err")})
        with pytest.raises(RuntimeError, match=r"앱 서버 wipe 실패\(Failed\): err \| 출력: out"):
            runner.app("wipe")
        assert runner.app("wipe", check=False) == "out"

    def test_command_quoted(self, runner, monkeypatch):
        runner.fetch_app = ""
        sent = []
        monkeypatch.setattr(runner, "apps", lambda: ["i-1"])
        monkeypatch.setattr(runner, "ssm", lambda ids, commands, timeout: sent.append(commands) or {"i-1": ("Success", "", "")})
        runner.app("sql", "SELECT 1; DROP x")
        assert "bash /opt/loadtest/infra/loadtest/agent/lt-app.sh /cking/loadtest sql 'SELECT 1; DROP x'" in sent[0]


class TestSteps:
    def test_exec_failure_stops(self, runner, monkeypatch):
        monkeypatch.setattr(runner, "exec_on", lambda on, run, timeout: {"i-1": ("Success", "ok", ""), "i-2": ("Failed", "", "boom")})
        with pytest.raises(RuntimeError, match="명령 실패: i-1: Success ok \\| i-2: Failed boom"):
            runner.step_exec({"on": "apps", "run": "x"})

    def test_check_fresh(self, runner, monkeypatch):
        monkeypatch.setattr(runner, "app", lambda cmd: "1\t1\t0\t0\n")
        assert runner.check_fresh() == "새 DB 확인(1 1 0 0)"
        monkeypatch.setattr(runner, "app", lambda cmd: "1\t1\t0\t5\n")
        with pytest.raises(RuntimeError, match="새 DB가 아님"):
            runner.check_fresh()

    def test_seed_ledger_mismatch(self, runner, monkeypatch, clock):
        monkeypatch.setattr(runner, "app", lambda *a, **k: "log\n1\t2\t1000\t5\t10\t100000\t0\n")
        with pytest.raises(RuntimeError, match="시딩 잔액·원장 불일치"):
            runner.step_seed({})

    def test_seed_records_vars(self, runner, monkeypatch, clock):
        monkeypatch.setattr(runner, "app", lambda *a, **k: "1\t2\t1000\t5\t10\t100000\t1\n")
        assert runner.step_seed({}) == "회원 1000, 크리에이터 5, 이벤트 10, 잔액 100000"
        assert (runner.vars["admin_member_id"], runner.vars["race_first_member_id"], runner.vars["race_balance"]) == (1, 2, 11)

    def test_seed_closing_already_past(self, runner, monkeypatch, clock):
        monkeypatch.setattr(runner, "app", lambda *a, **k: f"7\t{int(clock[0] * 1000) - 1}\n")
        with pytest.raises(RuntimeError, match="마감 시각이 이미 지남"):
            runner.step_seed_closing({})

    def test_wait_before_end_passed(self, runner, clock):
        runner.vars["end_at_ms"] = clock[0] * 1000 + 30_000
        with pytest.raises(RuntimeError, match="마감 60초 전이 이미 지남"):
            runner.step_wait({"before_end_seconds": 60})

    def test_wait_before_hour_skips_close_hour(self, runner, clock):
        clock[0] = 1_800_000_000 - 1_800_000_000 % 3600 + 3600 - 5 * 60 - 10
        runner.step_wait({"before_hour_minutes": 5})
        assert runner.vars["hour_at"] == ltrun.hms(1_800_000_000 - 1_800_000_000 % 3600 + 7200)

    def test_wait_event_closed_timeout(self, runner, monkeypatch, clock):
        runner.vars["closing_event_id"] = 7
        monkeypatch.setattr(runner, "app", lambda *a, **k: "OPEN\n")
        with pytest.raises(RuntimeError, match="이벤트 7가 시간 안에 마감되지 않음"):
            runner.step_wait({"event_closed": True, "timeout": "1m"})


class TestRun:
    def test_failure_recorded_and_reported(self, runner, monkeypatch):
        notified = []
        monkeypatch.setattr(runner, "step_setup", lambda step: "준비")
        monkeypatch.setattr(runner, "step_reset", lambda step: "되돌림")
        monkeypatch.setattr(runner, "step_seed", lambda step: "시딩")

        def verify(step):
            raise RuntimeError("PASS 1 / FAIL 1")

        monkeypatch.setattr(runner, "step_verify", verify)
        monkeypatch.setattr(runner, "notify", lambda status, error: notified.append((status, error)))
        assert runner.run() == 1
        state = json.loads((runner.dir / "state.json").read_text())
        assert (state["status"], state["error"]) == ("failed", "PASS 1 / FAIL 1")
        assert notified == [("failed", "PASS 1 / FAIL 1")]
        assert [(r["label"], r["ok"]) for r in runner.results] == [("setup", True), ("reset", True), ("seed", True), ("verify", False)]
        report = (runner.dir / "results.md").read_text()
        assert "| 1 | verify |" in report and "❌ 실패: PASS 1 / FAIL 1" in report

    def test_stop_is_not_failure_text(self, runner, monkeypatch):
        def stop(step):
            raise ltrun.Stop()

        monkeypatch.setattr(runner, "step_setup", stop)
        monkeypatch.setattr(runner, "notify", lambda status, error: None)
        assert runner.run() == 1
        assert json.loads((runner.dir / "state.json").read_text())["status"] == "stopped"
        assert runner.results[0]["text"] == "중지됨"

    def test_report_escapes_pipes(self, runner):
        runner.results.append({"round": 1, "type": "exec", "label": "exec", "start": 0, "end": 1, "ok": True, "text": "a | b\nc"})
        runner.write_report()
        assert "| 1 | exec | 00:00:00 | 0m01s | a \\| b c |" in (runner.dir / "results.md").read_text()


class TestBreached:
    SAMPLE = {"p95": 100, "n": 100, "fail": 0}

    @pytest.mark.parametrize("pending, lag, expected", [
        (5, 10, False),
        (5, 1001, True),
        (5, None, True),
        (None, None, False),
    ])
    def test_lag_over(self, pending, lag, expected):
        assert ltrun.breached({"lag_over": 1000}, self.SAMPLE, pending, lag) is expected

    def test_unknown_lag_ignored_without_lag_condition(self):
        assert ltrun.breached({"p95_ms": 500}, self.SAMPLE, 5, None) is False

    def test_p95_and_fail(self):
        assert ltrun.breached({"p95_ms": 50}, self.SAMPLE, 0, 0) is True
        assert ltrun.breached({"fail_pct": 1}, {"p95": 1, "n": 100, "fail": 2}, 0, 0) is True
        assert ltrun.breached({"fail_pct": 1}, {"p95": 1, "n": 0, "fail": 0}, 0, 0) is False
