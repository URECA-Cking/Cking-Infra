#!/usr/bin/env python3
"""부하 테스트 시나리오 실행기. k6 서버에서 root로 돈다(lt.sh start가 systemd-run으로 띄운다).

사용법: ltrun.py run --target <대상> --scenario <파일> --run-id <ID> --infra-commit <커밋> --be-commit <커밋>
        ltrun.py check <시나리오...>    형식만 검사한다(CI)

앱 서버 데이터 작업은 SSM(AWS-RunShellScript)으로 agent/lt-app.sh를, 지표 요약은 관측 서버 조회 문서를 부른다.
결과는 /opt/loadtest/runs/<ID>/에 쓰고 단계마다 결과 버킷 <대상>/<ID>/로 올린다.
"""
import argparse
import collections
import base64
import datetime
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import threading
import time
import tomllib
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REGION = "ap-northeast-2"
HERE = Path(__file__).resolve().parent
ROOT = Path("/opt/loadtest")
BE_LOADTEST = ROOT / "be" / "loadtest"
AGENT = "/opt/loadtest/infra/loadtest/agent/lt-app.sh"

SEED_DEFAULTS = {"creators": 5, "members": 10000, "start_balance": 100, "entry_hours": 24,
                 "race_members": 40, "race_balance": 11}
STEP_KEYS = {
    "reset": set(),
    "seed": set(),
    "seed_closing": {"creator", "minutes"},
    "wait": {"seconds", "until_utc", "before_hour_minutes", "before_end_seconds", "event_closed", "timeout"},
    "drain": {"timeout"},
    "k6": {"name", "script", "env", "args", "monitor_seconds", "hooks", "stop_when", "metrics"},
    "exec": {"on", "run", "timeout"},
    "verify": set(),
}
TOP_KEYS = {"name", "description", "repeat", "reset_before_round", "notify", "seed", "steps"}
HOOK_ON = {"k6", "app", "apps"}

# 단계 구간 [시작, 끝]의 지표 요약. $APP·$K6·$PREFIX는 대상의 instance 라벨, $D는 구간 초.
METRICS = [
    ("서버 응모 p95 (ms)", 1000, 'histogram_quantile(0.95, sum by (le) (increase(http_server_requests_seconds_bucket{instance=~"$APP",job="cking-be",method="POST",uri="/api/events/{eventId}/entries"}[$Ds])))'),
    ("서버 5xx (건)", 1, 'sum(increase(http_server_requests_seconds_count{instance=~"$APP",job="cking-be",status=~"5.."}[$Ds])) or vector(0)'),
    ("DB 반영 p95 (ms)", 1000, 'histogram_quantile(0.95, sum by (le) (increase(cking_stream_apply_delay_seconds_bucket{instance=~"$APP",stream="spend"}[$Ds])))'),
    ("DB 반영 1초 안 (%)", 100, 'sum(increase(cking_stream_apply_delay_seconds_bucket{instance=~"$APP",stream="spend",le="1.0"}[$Ds])) / sum(increase(cking_stream_apply_delay_seconds_count{instance=~"$APP",stream="spend"}[$Ds]))'),
    ("밀린 메시지 최대", 1, 'max(max_over_time(redis_stream_group_lag{job="redis",instance=~"$PREFIX.*",stream="stream:ticket-deducted"}[$Ds]))'),
    ("Hikari 대기 최대", 1, 'max(max_over_time(hikaricp_connections_pending{instance=~"$APP"}[$Ds]))'),
    ("앱 서버 CPU 최대 (%)", 100, 'max(max_over_time((1 - avg by (instance) (rate(node_cpu_seconds_total{job="node",instance=~"$APP",mode="idle"}[1m])))[$Ds:15s]))'),
    ("k6 서버 CPU 최대 (%)", 100, 'max(max_over_time((1 - avg by (instance) (rate(node_cpu_seconds_total{job="node",instance=~"$K6",mode="idle"}[1m])))[$Ds:15s]))'),
    ("JVM 힙 최대 (MiB)", 1 / 1048576, 'max(max_over_time(sum by (instance) (jvm_memory_used_bytes{instance=~"$APP",area="heap"})[$Ds:15s]))'),
    ("GC 정지 합계 (초)", 1, 'sum(increase(jvm_gc_pause_seconds_sum{instance=~"$APP"}[$Ds]))'),
]


class Stop(Exception):
    pass


def utc(ts=None):
    return datetime.datetime.fromtimestamp(ts if ts is not None else time.time(), datetime.timezone.utc)


def hms(ts):
    return utc(ts).strftime("%H:%M:%S")


def seconds(value):
    if isinstance(value, (int, float)):
        return float(value)
    m = re.fullmatch(r"(\d+(?:\.\d+)?)(s|m|h)?", str(value).strip())
    if not m:
        raise ValueError(f"시간 형식: {value} (예: 90, 90s, 5m, 1h)")
    return float(m[1]) * {"s": 1, "m": 60, "h": 3600, None: 1}[m[2]]


def span(sec):
    sec = int(round(sec))
    return f"{sec // 3600}h{sec % 3600 // 60:02d}m{sec % 60:02d}s" if sec >= 3600 else f"{sec // 60}m{sec % 60:02d}s"


def fill(text, values):
    """{이름}을 실행 변수로 바꾼다. 셸의 ${VAR}·awk {print}처럼 변수가 아닌 중괄호는 그대로 둔다."""
    return re.sub(r"\{(\w+)\}", lambda m: str(values[m[1]]) if m[1] in values else m[0], str(text))


def check_scenario(doc):
    errors = []
    for key in doc.keys() - TOP_KEYS:
        errors.append(f"알 수 없는 항목: {key}")
    for key in doc.get("seed", {}).keys() - SEED_DEFAULTS.keys():
        errors.append(f"seed: 알 수 없는 항목 {key}")
    steps = doc.get("steps")
    if not isinstance(steps, list) or not steps:
        errors.append("steps가 없다")
        return errors
    names = set()
    for i, step in enumerate(steps, 1):
        kind = step.get("type")
        where = f"steps[{i}] {kind}"
        if kind not in STEP_KEYS:
            errors.append(f"{where}: 알 수 없는 단계")
            continue
        for key in step.keys() - STEP_KEYS[kind] - {"type", "title"}:
            errors.append(f"{where}: 알 수 없는 항목 {key}")
        if kind == "k6":
            if not step.get("name") or not step.get("script"):
                errors.append(f"{where}: name·script 필요")
            if step.get("name") in names:
                errors.append(f"{where}: 이름 중복 {step['name']}")
            names.add(step.get("name"))
            for hook in step.get("hooks", []):
                if hook.get("on") not in HOOK_ON or not hook.get("run") or "after" not in hook:
                    errors.append(f"{where}: 훅은 after·on({'/'.join(sorted(HOOK_ON))})·run 필요")
            for key in step.get("stop_when", {}).keys() - {"p95_ms", "fail_pct", "lag_over", "consecutive"}:
                errors.append(f"{where}: stop_when 알 수 없는 항목 {key}")
        if kind == "wait":
            modes = {"seconds", "until_utc", "before_hour_minutes", "before_end_seconds", "event_closed"} & step.keys()
            if len(modes) != 1:
                errors.append(f"{where}: 기다릴 기준을 하나만 적는다 {sorted(modes)}")
        if kind == "exec" and (step.get("on") not in HOOK_ON or not step.get("run")):
            errors.append(f"{where}: on·run 필요")
        for key in ("seconds", "timeout", "monitor_seconds"):
            if key in step:
                try:
                    seconds(step[key])
                except ValueError as error:
                    errors.append(f"{where}: {error}")
    return errors


class Runner:
    def __init__(self, target_name, target, scenario_path, run_id, infra_commit, be_commit):
        self.target_name, self.t = target_name, target
        self.scenario_text = Path(scenario_path).read_text()
        self.sc = tomllib.loads(self.scenario_text)
        self.run_id = run_id
        self.dir = ROOT / "runs" / run_id
        (self.dir / "k6").mkdir(parents=True, exist_ok=True)
        self.timeline = open(self.dir / "timeline.log", "a", buffering=1)
        self.lock = threading.Lock()
        self.vars = {"run_id": run_id}
        self.seed_values = {**SEED_DEFAULTS, **self.sc.get("seed", {})}
        self.results = []
        self.meta = {"run_id": run_id, "target": target_name, "scenario": self.sc.get("name", Path(scenario_path).stem),
                     "infra_commit": infra_commit, "be_commit": be_commit}
        self.state = {"status": "starting", "started_at": utc().isoformat(timespec="seconds"), "step": None}
        self.k6_proc = None
        self.started = time.time()

    # 기록

    def log(self, message):
        line = f"{utc().strftime('%Y-%m-%dT%H:%M:%SZ')} {message}"
        with self.lock:
            self.timeline.write(line + "\n")
        print(line, flush=True)

    def save_state(self, **changes):
        self.state.update(changes)
        self.state["updated_at"] = utc().isoformat(timespec="seconds")
        (self.dir / "state.json").write_text(json.dumps({**self.meta, **self.state}, ensure_ascii=False, indent=2))

    def upload(self):
        dest = f"s3://{self.t['results_bucket']}/{self.target_name}/{self.run_id}/"
        done = subprocess.run(["aws", "s3", "sync", str(self.dir), dest, "--region", REGION, "--only-show-errors"],
                              capture_output=True, text=True)
        if done.returncode != 0:
            self.log(f"결과 올리기 실패: {done.stderr.strip()[:300]}")

    # AWS

    def aws(self, *args, check=True, timeout=120, env=None):
        done = subprocess.run(["aws", "--region", REGION, "--output", "json", *args],
                              capture_output=True, text=True, timeout=timeout, env=env)
        if done.returncode != 0:
            if check:
                raise RuntimeError(f"aws {' '.join(args[:2])}: {done.stderr.strip()[:500]}")
            return None
        return json.loads(done.stdout) if done.stdout.strip() else None

    def ssm(self, ids, commands=None, timeout=900, document="AWS-RunShellScript", parameters=None, env=None):
        """명령을 보내고 서버마다 (상태, 표준 출력, 표준 오류)를 돌려준다. 출력은 SSM 한도(약 24,000자)에서 잘린다."""
        params = parameters or {"commands": commands, "executionTimeout": [str(int(timeout))]}
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(params, f)
        try:
            cid = self.aws("ssm", "send-command", "--instance-ids", *ids, "--document-name", document,
                           "--parameters", f"file://{f.name}", "--query", "Command.CommandId", env=env)
        finally:
            os.unlink(f.name)
        deadline = time.time() + timeout + 120
        out = {}
        for instance in ids:
            while True:
                time.sleep(2)
                r = self.aws("ssm", "get-command-invocation", "--command-id", cid, "--instance-id", instance, check=False, env=env)
                if r is None or r["Status"] in ("Pending", "InProgress", "Delayed"):
                    if time.time() > deadline:
                        raise RuntimeError(f"SSM 명령 시간 초과 {instance} {cid}")
                    continue
                out[instance] = (r["Status"], r["StandardOutputContent"], r["StandardErrorContent"])
                break
        return out

    def bash_lines(self, script):
        # AWS-RunShellScript는 sh로 실행한다. bash 문법을 쓰도록 heredoc으로 감싼다.
        return ["bash -euo pipefail <<'LTEOF'", *script.splitlines(), "LTEOF"]

    def apps(self):
        if self.t.get("asg"):
            g = self.aws("autoscaling", "describe-auto-scaling-groups", "--auto-scaling-group-names", self.t["asg"])
            ids = sorted(i["InstanceId"] for i in g["AutoScalingGroups"][0]["Instances"] if i["LifecycleState"] == "InService")
        else:
            r = self.aws("ec2", "describe-instances", "--filters", f"Name=tag:Name,Values={self.t['app_name_tag']}",
                         "Name=instance-state-name,Values=running", "--query", "Reservations[].Instances[].InstanceId")
            ids = sorted(r)
        if not ids:
            raise RuntimeError("앱 서버를 찾지 못함")
        return ids

    def app(self, cmd, *args, on=None, check=True, timeout=900):
        """앱 서버 한 대(on이 없으면 첫 서버)에서 lt-app.sh를 실행하고 표준 출력을 돌려준다."""
        instance = on or self.apps()[0]
        line = " ".join(shlex.quote(a) for a in ["bash", AGENT, self.t["param_path"], cmd, *map(str, args)])
        status, out, err = self.ssm([instance], [line], timeout=timeout)[instance]
        if check and status != "Success":
            raise RuntimeError(f"앱 서버 {cmd} 실패({status}): {(err or out).strip()[-500:]}")
        return out

    def exec_on(self, on, command, timeout=900):
        command = fill(command, self.vars)
        if on == "k6":
            env = {k: v for k, v in os.environ.items() if k != "JWT_SECRET"}
            done = subprocess.run(["bash", "-c", command], capture_output=True, text=True, timeout=timeout, env=env)
            return {"k6": ("Success" if done.returncode == 0 else f"exit={done.returncode}", done.stdout, done.stderr)}
        ids = self.apps() if on == "apps" else self.apps()[:1]
        return self.ssm(ids, self.bash_lines(command), timeout=timeout)

    # 단계

    def step_setup(self, step):
        infra, be = self.meta["infra_commit"], self.meta["be_commit"]
        fetch = """
fetch() {
  rm -rf "/opt/loadtest/$1.new"; mkdir -p "/opt/loadtest/$1.new"
  curl -fsSL "https://codeload.github.com/URECA-Cking/$2/tar.gz/$3" | tar -xz --strip-components=1 -C "/opt/loadtest/$1.new"
  rm -rf "/opt/loadtest/$1"; mv "/opt/loadtest/$1.new" "/opt/loadtest/$1"; echo "$3" > "/opt/loadtest/$1/COMMIT"
}
"""
        # k6 서버의 Infra 코드는 lt.sh start가 이미 받아 이 실행기가 그걸로 돈다. BE만 받는다.
        subprocess.run(["bash", "-euo", "pipefail", "-c", f"{fetch}fetch be Cking-BE {be}"], check=True)
        fetch += f"fetch infra Cking-Infra {infra}\nfetch be Cking-BE {be}\n"
        ids = self.apps()
        for instance, (status, out, err) in self.ssm(ids, self.bash_lines(fetch), timeout=300).items():
            if status != "Success":
                raise RuntimeError(f"앱 서버 {instance} 코드 받기 실패: {err.strip()[-300:]}")
        self.jwt = self.aws("ssm", "get-parameter", "--name", f"{self.t['param_path']}/JWT_SECRET", "--with-decryption",
                            "--query", "Parameter.Value")
        rw = re.search(r'K6_PROMETHEUS_RW_SERVER_URL="([^"]+)"', Path("/etc/profile.d/k6.sh").read_text())
        self.rw_url = rw[1] if rw else ""
        k6_type = self.aws("ec2", "describe-instances", "--filters", f"Name=tag:Name,Values={self.t['k6_name_tag']}",
                           "Name=instance-state-name,Values=running", "--query", "Reservations[].Instances[].InstanceType")
        app_types = self.aws("ec2", "describe-instances", "--instance-ids", *ids, "--query", "Reservations[].Instances[].InstanceType")
        image = self.ssm(ids[:1], ["docker inspect -f '{{.Config.Image}}' cking-app"])[ids[0]][1].strip()
        self.meta.update(app_servers=len(ids), app_type=",".join(sorted(set(app_types))), k6_type=",".join(k6_type),
                         image_tag=image.rsplit(":", 1)[-1], seed=self.seed_values)
        self.log(f"준비: 앱 서버 {len(ids)}대({self.meta['app_type']}) k6 {self.meta['k6_type']} 이미지 {self.meta['image_tag']}")
        return f"앱 서버 {len(ids)}대, 이미지 {self.meta['image_tag']}"

    def step_reset(self, step):
        if self.t.get("asg"):
            return self.reset_asg()
        self.app("stop-app")
        out = self.app("wipe")
        if "초기화 완료" not in out:
            raise RuntimeError(f"초기화 출력 이상: {out.strip()[-300:]}")
        self.app("deploy", timeout=600)
        return self.check_fresh()

    def reset_asg(self):
        # BE docs/operations/loadtest.md "운영 데이터 되돌리기" 2·3·5·6·7·8단계. 실패하면 그룹 자동 교체를 멈춘 채로 둔다
        # (비정상 대상이 남은 채로 켜면 그룹이 서버를 교체한다).
        asg = self.t["asg"]
        self.aws("autoscaling", "suspend-processes", "--auto-scaling-group-name", asg)
        ids = self.apps()
        for instance in ids:
            self.app("stop-app", on=instance)
        out = self.app("wipe", on=ids[0])
        if "초기화 완료" not in out:
            raise RuntimeError(f"초기화 출력 이상: {out.strip()[-300:]}")
        for instance in ids:
            self.app("deploy", on=instance, timeout=600)
        tg = self.aws("elbv2", "describe-target-groups", "--names", self.t["target_group"],
                      "--query", "TargetGroups[0].TargetGroupArn")
        for _ in range(60):
            states = self.aws("elbv2", "describe-target-health", "--target-group-arn", tg,
                              "--query", "TargetHealthDescriptions[].TargetHealth.State")
            if states and all(s == "healthy" for s in states):
                break
            time.sleep(10)
        else:
            raise RuntimeError(f"ALB 대상이 healthy가 되지 않음: {states}")
        self.aws("autoscaling", "resume-processes", "--auto-scaling-group-name", asg)
        return f"서버 {len(ids)}대 재배포, " + self.check_fresh()

    def check_fresh(self):
        counts = self.app("fresh").split()
        if counts != ["1", "1", "0", "0"]:
            raise RuntimeError(f"새 DB가 아님(회원·관리자·크리에이터·이벤트): {counts}")
        return "새 DB 확인(1 1 0 0)"

    def step_seed(self, step):
        sets = "SET " + ", ".join(f"@{k} = {int(v)}" for k, v in self.seed_values.items())
        row = self.app("seed", sets, timeout=1800).strip().splitlines()[-1].split("\t")
        admin, race_first, members, creators, open_events, balances, ledger_ok = row
        if ledger_ok != "1":
            raise RuntimeError(f"시딩 잔액·원장 불일치: {row}")
        self.vars.update(admin_member_id=int(admin), race_first_member_id=int(race_first),
                         race_balance=self.seed_values["race_balance"])
        # 이벤트 Gate는 앱 일정 작업이 10초마다 Redis에 올린다
        time.sleep(15)
        return f"회원 {members}, 크리에이터 {creators}, 이벤트 {open_events}, 잔액 {balances}"

    def step_seed_closing(self, step):
        row = self.app("seed-closing", int(step.get("creator", 1)), int(step.get("minutes", 5))).strip().splitlines()[-1].split("\t")
        event_id, end_ms = int(row[0]), int(row[-1])
        if end_ms < time.time() * 1000:
            raise RuntimeError(f"마감 시각이 이미 지남: {row}")
        self.vars.update(closing_event_id=event_id, end_at_ms=end_ms)
        return f"이벤트 {event_id}, 마감 {hms(end_ms / 1000)}Z"

    def sleep_until(self, when, why):
        wait = when - time.time()
        self.log(f"대기 {span(max(wait, 0))} → {hms(when)}Z ({why})")
        self.save_state(waiting_until=utc(when).isoformat(timespec="seconds"))
        self.upload()
        while time.time() < when:
            time.sleep(min(30, max(when - time.time(), 0.05)))
        self.save_state(waiting_until=None)
        return f"{span(max(wait, 0))} 대기 → {hms(when)}Z"

    def step_wait(self, step):
        now = time.time()
        if "seconds" in step:
            return self.sleep_until(now + seconds(step["seconds"]), "고정")
        if "until_utc" in step:
            h, m, *s = map(int, step["until_utc"].split(":"))
            day = utc(now).replace(hour=h, minute=m, second=s[0] if s else 0, microsecond=0)
            if day.timestamp() <= now:
                day += datetime.timedelta(days=1)
            return self.sleep_until(day.timestamp(), f"UTC {step['until_utc']}")
        if "before_hour_minutes" in step:
            # 다음 정각 N분 전. 30초도 안 남았으면 그다음 정각으로 넘긴다.
            hour = (int(now) // 3600 + 1) * 3600
            when = hour - seconds(step["before_hour_minutes"]) * 60
            while when < now + 30:
                hour += 3600
                when += 3600
            self.vars["hour_at"] = hms(hour)
            return self.sleep_until(when, f"정각 {hms(hour)}Z {step['before_hour_minutes']}분 전")
        if "before_end_seconds" in step:
            when = self.vars["end_at_ms"] / 1000 - seconds(step["before_end_seconds"])
            if when < now:
                raise RuntimeError(f"마감 {step['before_end_seconds']}초 전이 이미 지남")
            return self.sleep_until(when, f"마감 {step['before_end_seconds']}초 전")
        deadline = now + seconds(step.get("timeout", "15m"))
        eid = self.vars["closing_event_id"]
        while time.time() < deadline:
            status = self.app("sql", f"SELECT status FROM event WHERE event_id = {eid}").strip()
            if status in ("CLOSED", "DRAW_COMPLETED", "PUBLISHED"):
                return f"이벤트 {eid} {status}"
            time.sleep(10)
        raise RuntimeError(f"이벤트 {eid}가 시간 안에 마감되지 않음")

    def stream(self):
        out = self.app("redis", "XINFO", "GROUPS", "stream:ticket-deducted", check=False, timeout=60)
        if "no such key" in out or not out.strip():
            return 0, 0
        tokens = out.split()
        nums = collections.defaultdict(int)
        for key, value in zip(tokens, tokens[1:]):
            if key in ("pending", "lag") and value.lstrip("-").isdigit():
                nums[key] += int(value)
        return nums["pending"], nums["lag"]

    def step_drain(self, step):
        deadline = time.time() + seconds(step.get("timeout", "20m"))
        start = time.time()
        while True:
            pending, lag = self.stream()
            if pending == 0 and lag == 0:
                return f"밀린 메시지 0 ({span(time.time() - start)})"
            if time.time() > deadline:
                raise RuntimeError(f"밀린 메시지가 빠지지 않음 pending={pending} lag={lag}")
            self.log(f"반영 대기 pending={pending} lag={lag}")
            time.sleep(15)

    def step_exec(self, step):
        out = self.exec_on(step["on"], step["run"], timeout=seconds(step.get("timeout", "15m")))
        text = self.hook_text(out)
        if any(s != "Success" for s, _, _ in out.values()):
            raise RuntimeError(f"명령 실패: {text}")
        return text

    def hook_text(self, out):
        return " | ".join(f"{k}: {s} {(o or e).strip()[-200:]}".strip() for k, (s, o, e) in out.items())

    def asg_text(self):
        if not self.t.get("asg"):
            return ""
        g = self.aws("autoscaling", "describe-auto-scaling-groups", "--auto-scaling-group-names", self.t["asg"], check=False)
        if not g:
            return ""
        g = g["AutoScalingGroups"][0]
        return f" asg={g['DesiredCapacity']}/{sum(i['LifecycleState'] == 'InService' for i in g['Instances'])}"

    def step_k6(self, step):
        rnd = self.vars["round"]
        name = step["name"]
        base = self.dir / "k6" / f"r{rnd}-{name}"
        testid = f"{self.run_id}-r{rnd}-{name}"
        env = {**os.environ, "BASE_URL": self.t["base_url"], "JWT_SECRET": self.jwt,
               "CREATORS": str(self.seed_values["creators"]), "MEMBERS": str(self.seed_values["members"]),
               "K6_PROMETHEUS_RW_SERVER_URL": self.rw_url, "K6_PROMETHEUS_RW_TREND_STATS": "p(50),p(95),p(99),max"}
        if self.t.get("confirm_prod"):
            env["CONFIRM_PROD"] = self.t["confirm_prod"]
        env.update({k: fill(v, self.vars) for k, v in step.get("env", {}).items()})
        cmd = ["k6", "run", "-o", "experimental-prometheus-rw", "--tag", f"testid={testid}", "--log-format", "raw",
               "--console-output", f"{base}.log", "--summary-export", f"{base}.summary.json",
               "--summary-trend-stats", "avg,min,med,max,p(90),p(95),p(99)",
               *[fill(a, self.vars) for a in step.get("args", [])], step["script"]]
        interval = seconds(step.get("monitor_seconds", 30))
        stop = step.get("stop_when", {})
        hooks = sorted(({**h, "at": seconds(h["after"])} for h in step.get("hooks", [])), key=lambda h: h["at"])
        hook_results, threads = [], []
        window = EntryWindow(f"{base}.log", interval)
        self.log(f"k6 {name} 시작 testid={testid} {' '.join(f'{k}={v}' for k, v in step.get('env', {}).items())}")
        with open(f"{base}.out.txt", "w") as out:
            self.k6_proc = subprocess.Popen(cmd, cwd=BE_LOADTEST, env=env, stdout=out, stderr=subprocess.STDOUT)
        start = time.time()
        next_sample, breaches, stopped = start + interval, 0, None
        while self.k6_proc.poll() is None:
            time.sleep(1)
            now = time.time()
            while hooks and now - start >= hooks[0]["at"]:
                hook = hooks.pop(0)
                t = threading.Thread(target=self.run_hook, args=(hook, start, hook_results), daemon=True)
                t.start()
                threads.append(t)
            if now >= next_sample:
                next_sample += interval
                s = window.read()
                pending, lag = self.stream()
                self.log(f"k6 {name} t={int(now - start)}s n={s['n']} rps={s['rps']:.1f} p95={s['p95']} fail={s['fail']} "
                         f"pending={pending} lag={lag}{self.asg_text()} codes={s['codes']}")
                hit = ((stop.get("p95_ms") is not None and (s["p95"] or 0) > stop["p95_ms"])
                       or (stop.get("fail_pct") is not None and s["n"] and s["fail"] * 100 > stop["fail_pct"] * s["n"])
                       or (stop.get("lag_over") is not None and lag > stop["lag_over"]))
                breaches = breaches + 1 if hit else 0
                if stop and not stopped and breaches >= stop.get("consecutive", 2):
                    stopped = f"중단 조건 {breaches}회 연속(p95={s['p95']} fail={s['fail']}/{s['n']} lag={lag})"
                    self.log(f"k6 {name} {stopped} → k6 중단")
                    self.k6_proc.send_signal(signal.SIGINT)
        end = time.time()
        code = self.k6_proc.returncode
        self.k6_proc = None
        for t in threads:
            t.join(timeout=900)
        entries = entry_stats(f"{base}.log")
        summary = k6_summary(f"{base}.summary.json")
        metrics = self.metrics(start, end) if step.get("metrics", True) else []
        result = {"testid": testid, "exit": code, "start": start, "end": end, "entries": entries, "summary": summary,
                  "metrics": metrics, "hooks": hook_results, "stopped": stopped}
        (Path(f"{base}.result.json")).write_text(json.dumps(result, ensure_ascii=False, indent=2))
        # 0 통과, 99 합격선 미달, 그 밖(108 abortOnFail 등)은 실행이 끊긴 것. 측정 결과라 실행기는 다음 단계로 간다.
        verdict = "중단 조건으로 멈춤" if stopped else {0: "통과", 99: "합격선 미달"}.get(code, f"k6 종료 코드 {code}")
        return {"text": f"{verdict}, 응모 {entries['n']}건 p95 {entries['p95']}ms 실패 {entries['fail']}", "k6": result}

    def run_hook(self, hook, start, results):
        at = time.time()
        self.log(f"훅 t={int(at - start)}s on={hook['on']} 실행: {hook['run']}")
        try:
            out = self.exec_on(hook["on"], hook["run"], timeout=seconds(hook.get("timeout", "15m")))
            text = self.hook_text(out)
        except Exception as error:
            text = f"오류 {error}"
        self.log(f"훅 끝 {span(time.time() - at)}: {text[:500]}")
        results.append({"after": hook["after"], "on": hook["on"], "run": hook["run"], "at": hms(at), "took": round(time.time() - at, 1), "result": text})

    def metrics(self, start, end):
        # 관측 서버는 15초마다 긁는다. 마지막 구간이 들어올 때까지 기다린다.
        time.sleep(30)
        observability = self.aws("ec2", "describe-instances", "--filters", f"Name=tag:Name,Values={self.t['query_instance_name_tag']}",
                                 "Name=instance-state-name,Values=running", "--query", "Reservations[].Instances[].InstanceId")
        if not observability:
            return [{"name": "지표", "value": "관측 서버 없음"}]
        app_re = self.t["app_name_tag"] if self.t.get("app_name_tag") else f"{self.t['asg']}.*"
        dur = max(60, int(end - start))
        # 조회 문서만 보낼 수 있는 역할로 넘어간다(envs/loadtest-base iam.tf)
        c = self.aws("sts", "assume-role", "--role-arn", self.t["query_role_arn"], "--role-session-name", f"ltrun-{self.run_id}"[:64],
                     "--query", "Credentials")
        env = {**os.environ, "AWS_ACCESS_KEY_ID": c["AccessKeyId"], "AWS_SECRET_ACCESS_KEY": c["SecretAccessKey"],
               "AWS_SESSION_TOKEN": c["SessionToken"]}

        def one(item):
            title, scale, query = item
            q = query.replace("$APP", app_re).replace("$K6", self.t["k6_name_tag"]).replace("$PREFIX", self.t["instance_prefix"]).replace("$D", str(dur))
            params = {"kind": ["prometheus"], "query": [base64.b64encode(q.encode()).decode()], "minutes": ["30"], "end": [str(int(end))]}
            try:
                status, out, err = self.ssm(observability[:1], document=self.t["query_document"], parameters=params, timeout=90, env=env)[observability[0]]
                series = json.loads(out).get("series", [])
                value = float(series[0]["value"]) * scale if series else None
                return {"name": title, "value": None if value is None or value != value else round(value, 1)}
            except Exception as error:
                return {"name": title, "value": f"조회 실패 {str(error)[:100]}"}

        with ThreadPoolExecutor(max_workers=5) as pool:
            return list(pool.map(one, METRICS))

    def step_verify(self, step):
        rnd = self.vars["round"]
        eid = self.vars.get("closing_event_id")
        out = self.app("verify", *([eid] if eid else []), check=False, timeout=1800)
        lines = [l for l in out.splitlines() if l.startswith(("PASS", "FAIL", "=="))]
        db = {}
        for row in self.app("sql", "SELECT event_id, COUNT(*) FROM event_entry GROUP BY event_id").split("\n"):
            if row.strip():
                k, v = row.split("\t")
                db[int(k)] = int(v)
        k6 = collections.Counter()
        after_end = 0
        race = collections.defaultdict(list)
        for log in sorted((self.dir / "k6").glob(f"r{rnd}-*.log")):
            for d in records(log):
                if d.get("code") == "SUCCESS":
                    k6[int(d["eventId"])] += 1
                    if self.vars.get("end_at_ms") and int(d["eventId"]) == eid and d["sentAt"] > self.vars["end_at_ms"] + 1000:
                        after_end += 1
                if d.get("phase") in ("race_same", "race_over"):
                    race[(int(d["round"]), d["phase"])].append(d)
        checks = [("k6 성공 = DB 응모(이벤트별)", dict(sorted(k6.items())) == dict(sorted(db.items())), f"k6 {dict(sorted(k6.items()))} DB {dict(sorted(db.items()))}")]
        if eid:
            checks.append(("마감 1초 뒤 성공 0건", after_end == 0, f"{after_end}건"))
        if race:
            bal = int(self.vars["race_balance"])
            bad = 0
            for (n, phase), ds in race.items():
                c = collections.Counter(d["code"] for d in ds)
                want, rest = (1, "DUPLICATE_REPLAY") if phase == "race_same" else (bal - 1, "INSUFFICIENT_BALANCE")
                bad += not (c["SUCCESS"] == want and c["SUCCESS"] + c[rest] == len(ds))
            checks.append(("동시 요청 라운드 판정", bad == 0, f"실패 라운드 {bad}/{len(race)}"))
        for title, ok, detail in checks:
            lines.append(f"{'PASS' if ok else 'FAIL'}  {title}  {detail}")
        (self.dir / f"r{rnd}-verify.txt").write_text(out + "\n" + "\n".join(lines[-len(checks):]) + "\n")
        fails = sum(l.startswith("FAIL") for l in lines)
        passes = sum(l.startswith("PASS") for l in lines)
        return {"text": f"PASS {passes} / FAIL {fails}", "verify": lines}

    # 실행

    def step(self, step):
        kind = step["type"]
        label = step.get("name") or step.get("title") or kind
        rnd = self.vars.get("round", 0)
        self.save_state(step=f"r{rnd} {label}")
        self.log(f"── r{rnd} {label} 시작")
        start = time.time()
        record = {"round": rnd, "type": kind, "label": label, "start": start}
        try:
            out = getattr(self, f"step_{kind}")(step)
            record.update(out if isinstance(out, dict) else {"text": out})
            record["ok"] = True
        except Stop:
            record.update(ok=False, text="중지됨")
            raise
        except Exception as error:
            record.update(ok=False, text=f"실패: {error}")
            raise
        finally:
            record["end"] = time.time()
            self.results.append(record)
            self.log(f"── r{rnd} {label} {'끝' if record['ok'] else '실패'} {span(record['end'] - start)}: {str(record.get('text'))[:300]}")
            self.write_report()
            self.save_state()
            self.upload()

    def run(self):
        signal.signal(signal.SIGTERM, self.on_term)
        self.save_state(status="running")
        status, error = "done", None
        try:
            self.vars["round"] = 0
            self.step({"type": "setup"})
            for rnd in range(1, int(self.sc.get("repeat", 1)) + 1):
                for key in ("closing_event_id", "end_at_ms", "hour_at"):
                    self.vars.pop(key, None)
                self.vars["round"] = rnd
                if self.sc.get("reset_before_round", True):
                    self.step({"type": "reset"})
                    self.step({"type": "seed"})
                for step in self.sc["steps"]:
                    self.step(step)
        except Stop:
            status = "stopped"
        except Exception as error_:
            status, error = "failed", str(error_)
        self.save_state(status=status, error=error, step=None, finished_at=utc().isoformat(timespec="seconds"))
        self.write_report()
        self.upload()
        self.log(f"실행 {status} {span(time.time() - self.started)}")
        if self.sc.get("notify", True):
            self.notify(status, error)
        return 0 if status == "done" else 1

    def on_term(self, *_):
        if self.k6_proc and self.k6_proc.poll() is None:
            self.k6_proc.send_signal(signal.SIGINT)
        raise Stop()

    def notify(self, status, error):
        # 웹훅 주소는 비밀이라 로그에 남기지 않는다. 메시지에는 요약 숫자와 결과 위치만 담는다.
        try:
            url = self.aws("ssm", "get-parameter", "--name", self.t["slack_webhook_parameter"], "--with-decryption", "--query", "Parameter.Value")
            lines = [f"부하 테스트 {self.meta['scenario']} ({self.target_name}) {status} · {span(time.time() - self.started)}"]
            for r in self.results:
                if r["type"] in ("k6", "verify"):
                    lines.append(f"• r{r['round']} {r['label']}: {r.get('text')}")
            if error:
                lines.append(f"• 오류: {error[:300]}")
            lines.append(f"결과: s3://{self.t['results_bucket']}/{self.target_name}/{self.run_id}/results.md")
            body = json.dumps({"text": "\n".join(lines)}).encode()
            urllib.request.urlopen(urllib.request.Request(url, body, {"Content-Type": "application/json"}), timeout=10).read()
            self.log("Slack 알림 보냄")
        except Exception as error_:
            self.log(f"Slack 알림 실패: {type(error_).__name__}")

    # 보고서

    def write_report(self):
        m, s = self.meta, self.state
        out = [f"# 부하 테스트 {m['scenario']} · {self.run_id}", "",
               "| 항목 | 값 |", "|---|---|",
               f"| 대상 | {self.target_name} ({self.t['base_url']}) |",
               f"| 상태 | {s.get('status')} {s.get('error') or ''} |",
               f"| 시작·끝(UTC) | {s.get('started_at')} → {s.get('finished_at') or '진행 중'} ({span(time.time() - self.started)}) |",
               f"| Infra 커밋 | {m['infra_commit']} |", f"| BE 커밋 | {m['be_commit']} |",
               f"| 이미지 태그 | {m.get('image_tag', '-')} |",
               f"| 서버 | 앱 {m.get('app_servers', '-')}대 {m.get('app_type', '-')}, k6 {m.get('k6_type', '-')} |",
               f"| 시딩 | {' '.join(f'{k}={v}' for k, v in self.seed_values.items())} |", "",
               "## 단계", "", "| 라운드 | 단계 | 시작(UTC) | 걸린 시간 | 결과 |", "|---|---|---|---|---|"]
        for r in self.results:
            text = str(r.get("text", "")).replace("|", "\\|").replace("\n", " ")
            out.append(f"| {r['round']} | {r['label']} | {hms(r['start'])} | {span(r['end'] - r['start'])} | {'' if r['ok'] else '❌ '}{text} |")
        k6_steps = [r for r in self.results if r.get("k6")]
        if k6_steps:
            out += ["", "## k6", "", "| 라운드 | 단계 | 응모 | 초당 | p50 | p95 | p99 | 최대 | 실패 | 결과 코드 | 전체 p95 | dropped | 종료 |",
                    "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
            for r in k6_steps:
                e, sm = r["k6"]["entries"], r["k6"]["summary"]
                out.append(f"| {r['round']} | {r['label']} | {e['n']} | {e['rps']} | {e['p50']} | {e['p95']} | {e['p99']} | {e['max']} | "
                           f"{e['fail']} | {e['codes']} | {sm.get('p95', '-')} | {sm.get('dropped', 0)} | {r['k6']['exit']} |")
            names = [x["name"] for x in k6_steps[0]["k6"]["metrics"]]
            if names:
                out += ["", "## 지표 요약 (단계 구간)", "", "| 라운드 | 단계 | " + " | ".join(names) + " |", "|---|---|" + "---|" * len(names)]
                for r in k6_steps:
                    out.append(f"| {r['round']} | {r['label']} | " + " | ".join(str(x["value"]) for x in r["k6"]["metrics"]) + " |")
            out.append("")
            for r in k6_steps:
                for h in r["k6"]["hooks"]:
                    out.append(f"- 훅 r{r['round']} {r['label']} {h['after']} 뒤({h['at']}Z, {h['took']}초) {h['on']}: `{h['run']}` → {h['result'][:300]}")
                if r["k6"]["stopped"]:
                    out.append(f"- r{r['round']} {r['label']}: {r['k6']['stopped']}")
        for r in self.results:
            if r.get("verify"):
                out += ["", f"## 검증 r{r['round']}", "", "```text", *r["verify"], "```"]
        out += ["", "## 시나리오", "", "```toml", self.scenario_text.strip(), "```", "",
                "원자료: `timeline.log`(30초 감시), `k6/r<라운드>-<단계>.log`(요청별), `.summary.json`, `.out.txt`, `r<라운드>-verify.txt`", ""]
        (self.dir / "results.md").write_text("\n".join(out))


class EntryWindow:
    """k6 요청별 기록을 이어 읽어 최근 N초의 응모 지연·결과를 낸다."""

    def __init__(self, path, window):
        self.path, self.window, self.offset = path, window, 0
        self.rows = collections.deque()

    def read(self):
        try:
            with open(self.path, "rb") as f:
                f.seek(self.offset)
                chunk = f.read()
            cut = chunk.rfind(b"\n") + 1
            self.offset += cut
            for line in chunk[:cut].decode(errors="replace").splitlines():
                d = parse(line)
                if d and d.get("kind") == "entry":
                    self.rows.append((d["at"], d["at"] - d["sentAt"], d["code"]))
        except FileNotFoundError:
            pass
        floor = time.time() * 1000 - self.window * 1000
        while self.rows and self.rows[0][0] < floor:
            self.rows.popleft()
        lat = sorted(r[1] for r in self.rows)
        codes = collections.Counter(r[2] for r in self.rows)
        n = len(lat)
        return {"n": n, "rps": n / self.window, "p95": lat[min(n - 1, int(0.95 * n))] if n else None,
                "fail": n - codes.get("SUCCESS", 0), "codes": dict(codes)}


def parse(line):
    if not line.startswith("{"):
        return None
    try:
        return json.loads(line)
    except ValueError:
        return None


def records(path):
    with open(path) as f:
        for line in f:
            d = parse(line)
            if d and d.get("kind") == "entry":
                yield d


def entry_stats(path):
    lat, codes, first, last = [], collections.Counter(), None, None
    if Path(path).exists():
        for d in records(path):
            lat.append(d["at"] - d["sentAt"])
            codes[d["code"]] += 1
            first = d["sentAt"] if first is None else min(first, d["sentAt"])
            last = d["sentAt"] if last is None else max(last, d["sentAt"])
    lat.sort()
    n = len(lat)
    q = lambda p: lat[min(n - 1, int(p * n))] if n else None
    rps = round(n / max((last - first) / 1000, 1), 1) if n else 0
    return {"n": n, "rps": rps, "p50": q(0.5), "p95": q(0.95), "p99": q(0.99), "max": lat[-1] if n else None,
            "fail": n - codes.get("SUCCESS", 0), "codes": dict(codes)}


def k6_summary(path):
    try:
        metrics = json.loads(Path(path).read_text()).get("metrics", {})
    except (OSError, ValueError):
        return {}
    pick = lambda name, key: metrics.get(name, {}).get(key, metrics.get(name, {}).get("values", {}).get(key))
    p95 = pick("http_req_duration", "p(95)")
    return {"p95": round(p95, 1) if p95 is not None else None, "reqs": pick("http_reqs", "count"),
            "failed_rate": pick("http_req_failed", "value") if pick("http_req_failed", "value") is not None else pick("http_req_failed", "rate"),
            "dropped": pick("dropped_iterations", "count") or 0}


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    run = sub.add_parser("run")
    run.add_argument("--target", required=True)
    run.add_argument("--scenario", required=True)
    run.add_argument("--run-id", required=True)
    run.add_argument("--infra-commit", required=True)
    run.add_argument("--be-commit", required=True)
    check = sub.add_parser("check")
    check.add_argument("files", nargs="+")
    args = ap.parse_args()

    if args.cmd == "check":
        bad = 0
        for f in args.files:
            errors = check_scenario(tomllib.loads(Path(f).read_text()))
            for e in errors:
                print(f"{f}: {e}")
            bad += bool(errors)
        return 1 if bad else 0

    targets = tomllib.loads((HERE / "targets.toml").read_text())
    if args.target not in targets:
        raise SystemExit(f"알 수 없는 대상: {args.target}")
    errors = check_scenario(tomllib.loads(Path(args.scenario).read_text()))
    if errors:
        raise SystemExit("시나리오 오류: " + "; ".join(errors))
    return Runner(args.target, targets[args.target], args.scenario, args.run_id, args.infra_commit, args.be_commit).run()


if __name__ == "__main__":
    sys.exit(main())
