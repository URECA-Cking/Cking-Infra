"""lt.sh의 ssm·wait. aws는 가짜 스크립트로, sleep은 bash의 SECONDS만 앞으로 돌리는 함수로 바꾼다."""
import json
import os
import subprocess
from pathlib import Path

import pytest

LT_SH = Path(__file__).resolve().parent.parent / "lt.sh"
DISPATCH = "\nc=${1:-}; shift || true\n"

FAKE_AWS = r"""#!/bin/bash
echo "$*" >> "$FAKE_LOG"
case "$1 $2" in
  "ssm send-command")
    [ "$FAKE_SEND" = fail ] && { echo "An error occurred (InvalidInstanceId)" >&2; exit 254; }
    echo cmd-1 ;;
  "ssm get-command-invocation")
    case "$*" in
      *"--query Status"*)
        [ -z "$FAKE_STATUS" ] && { echo "An error occurred (InvocationDoesNotExist)" >&2; exit 254; }
        echo "$FAKE_STATUS" ;;
      *StandardOutputContent*) printf '%s\n' "$FAKE_STDOUT" ;;
      *StandardErrorContent*) printf '%s\n' "$FAKE_STDERR" ;;
    esac ;;
  "ec2 describe-instances") echo "$FAKE_K6" ;;
  "s3 cp")
    [ -n "$FAKE_STATE" ] || exit 1
    echo "$FAKE_STATE" ;;
  "s3 sync") ;;
  *) echo "unexpected aws $*" >&2; exit 99 ;;
esac
"""


@pytest.fixture
def lt(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    aws = bin_dir / "aws"
    aws.write_text(FAKE_AWS)
    aws.chmod(0o755)
    text = LT_SH.read_text()
    assert DISPATCH in text, "lt.sh 끝의 명령 분기 줄이 바뀌었다. 테스트의 DISPATCH를 맞춘다"
    functions = tmp_path / "lt-functions.sh"
    functions.write_text(text.split(DISPATCH)[0] + '\nsleep() { SECONDS=$((SECONDS + $1)); }\n')
    log = tmp_path / "aws.log"

    def run(script, timeout=30, **fake):
        env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "FAKE_LOG": str(log), "LT_OUT": str(tmp_path / "out"),
               "FAKE_SEND": "", "FAKE_STATUS": "Success", "FAKE_STDOUT": "", "FAKE_STDERR": "", "FAKE_K6": "i-k6", "FAKE_STATE": ""}
        env.update({f"FAKE_{k.upper()}": v for k, v in fake.items() if k != "env"})
        env.update(fake.get("env", {}))
        try:
            done = subprocess.run(["bash", "-c", f'source "$0"\n{script}', str(functions)], capture_output=True, text=True,
                                  timeout=timeout, env=env)
        except subprocess.TimeoutExpired:
            pytest.fail(f"{timeout}초 안에 끝나지 않았다: {script}")
        calls = log.read_text().splitlines() if log.exists() else []
        log.unlink(missing_ok=True)
        return done, calls

    return run


def state(status, step=None):
    return json.dumps({"status": status, "step": step})


class TestSsm:
    def test_success_prints_stdout(self, lt):
        done, calls = lt("ssm i-1 60 'echo hi'", stdout="hi")
        assert done.returncode == 0
        assert done.stdout == "hi\n"
        assert calls[0].startswith("ssm send-command --region ap-northeast-2 --instance-ids i-1 --document-name AWS-RunShellScript")

    def test_failed_status(self, lt):
        done, _ = lt("ssm i-1 60 'false'", status="Failed", stdout="partial", stderr="boom")
        assert done.returncode == 1
        assert "SSM Failed (i-1)" in done.stderr
        assert "boom" in done.stderr

    def test_send_failure_returns(self, lt):
        """#259: 전송이 실패하면 빈 명령 ID로 상태를 계속 묻지 않고 바로 실패한다. 호출부가 || 로 받으면 set -e가 꺼진다."""
        done, calls = lt("ssm i-1 60 'echo' || exit $?", send="fail")
        assert done.returncode == 1
        assert "SSM 전송 실패 (i-1)" in done.stderr
        assert not any("get-command-invocation" in c for c in calls)

    @pytest.mark.parametrize("status,shown", [("", "없음"), ("InProgress", "InProgress")])
    def test_status_deadline(self, lt, status, shown):
        """#259: 상태를 못 읽거나 끝나지 않으면 실행 제한 + 2분에 끊는다."""
        done, calls = lt("ssm i-1 60 'echo' || { echo \"rc=$? t=$SECONDS\"; exit 1; }", status=status)
        assert done.returncode == 1
        assert f"SSM 상태 확인 시간 초과 (i-1, 마지막 상태 {shown})" in done.stderr
        elapsed = int(done.stdout.split("t=")[1])
        assert 180 <= elapsed <= 183
        assert sum("--query Status" in c for c in calls) == elapsed // 3


class TestWait:
    def test_done(self, lt):
        done, calls = lt("cmd_wait run-1", state=state("done"))
        assert done.returncode == 0
        assert calls[-1].startswith("s3 sync --region ap-northeast-2 --only-show-errors s3://")
        assert "/loadtest/run-1/" in calls[-1]

    @pytest.mark.parametrize("status", ["failed", "stopped"])
    def test_finished_not_done(self, lt, status):
        done, calls = lt("cmd_wait run-1", state=state(status, "r1 verify"))
        assert done.returncode == 1
        assert calls[-1].startswith("s3 sync")

    def test_runner_lost(self, lt):
        """#259: 실행기 unit이 죽어 state.json이 running에 머물면 다섯 번째 확인에서 실패로 끝낸다."""
        done, calls = lt("cmd_wait run-1 || { echo \"rc=$? t=$SECONDS\"; exit 1; }", state=state("running", "r1 sustain"),
                         stdout="inactive")
        assert done.returncode == 1
        assert "run-1 실행기 종료됨(unit inactive), 상태 running r1 sustain" in done.stderr
        assert "run-1 failed runner-lost" in done.stderr
        assert sum(c.startswith("ssm send-command") for c in calls) == 1
        assert calls[-1].startswith("s3 sync")
        assert int(done.stdout.split("t=")[1]) < 5 * 60

    @pytest.mark.parametrize("unit", ["active", "activating"])
    def test_runner_alive_keeps_waiting_until_limit(self, lt, unit):
        """#259: 살아 있어도 LT_WAIT_MAX_SECONDS를 넘기면 실패로 끝낸다."""
        done, calls = lt("cmd_wait run-1", state=state("running", "r1 sustain"), stdout=unit, env={"LT_WAIT_MAX_SECONDS": "900"})
        assert done.returncode == 1
        assert "run-1 대기 시간 초과 (running r1 sustain)" in done.stderr
        assert "run-1 failed wait-timeout" in done.stderr
        assert sum(c.startswith("ssm send-command") for c in calls) == 3

    def test_unit_check_failure_is_not_runner_lost(self, lt):
        done, _ = lt("cmd_wait run-1", state=state("running"), send="fail", env={"LT_WAIT_MAX_SECONDS": "600"})
        assert done.returncode == 1
        assert "runner-lost" not in done.stderr
        assert "wait-timeout" in done.stderr

    def test_missing_state_counts_as_starting(self, lt):
        done, _ = lt("cmd_wait run-1", env={"LT_WAIT_MAX_SECONDS": "120"}, stdout="active")
        assert done.returncode == 1
        assert "run-1 starting" in done.stderr
