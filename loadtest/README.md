# 부하 테스트 실행 자동화

시나리오 파일 하나로 되돌리기 → 시딩 → k6 → 감시 → 검증 → 결과 정리를 끝까지 돌린다. 측정 절차와 시나리오 스크립트(`loadtest/*.js`, `seed.sql`, `verify.sh`)는 Cking-BE `docs/operations/loadtest.md`가 기준이고, 여기는 그 절차를 사람 대신 실행하는 쪽이다.

| 파일 | 실행 위치 | 내용 |
|---|---|---|
| `lt.sh` | Mac(저장소 루트) | 환경 생성·앱 배포·실행 시작·대기·결과 받기·삭제 |
| `runner/ltrun.py` | k6 서버(root) | 시나리오 실행기. `lt.sh start`가 `systemd-run`으로 띄운다 |
| `runner/targets.toml` | | 대상별 주소·Parameter Store 경로·서버 이름표·결과 버킷 |
| `agent/lt-app.sh` | 앱 서버(root) | 실행기가 SSM으로 부르는 DB·Redis·되돌리기·배포·검증 |
| `scenarios/*.toml` | | 시나리오 |

## 실행

```bash
loadtest/lt.sh all loadtest/scenarios/smoke.toml
```

`all`은 `up`(apply) → `prepare`(개발 앱 서버와 같은 이미지 태그로 배포, 수집기) → `start` → `wait` → `down`(destroy)이고, 중간에 실패하거나 멈춰도 `down`을 한다. 단계별로 나눠 돌릴 수도 있다.

```bash
loadtest/lt.sh up
loadtest/lt.sh prepare                       # 태그를 주면 그 이미지로
loadtest/lt.sh start loadtest/scenarios/baseline.toml   # 실행 ID 출력
loadtest/lt.sh status <실행 ID>
loadtest/lt.sh wait <실행 ID>                 # 끝나면 ./loadtest-runs/<ID>/로 받는다
loadtest/lt.sh down
```

- 실행기 코드는 `start`를 부른 저장소의 HEAD 커밋을 k6 서버가 GitHub에서 받는다. 원격에 없는 커밋이면 멈춘다
- 시나리오 파일은 커밋하지 않아도 된다. `start`가 파일 내용을 실행 폴더에 올린다
- BE 커밋은 앱 이미지 태그(`<시각>-<커밋>`)에서 읽는다. 측정 스크립트와 앱이 같은 커밋이다
- 실행기는 SSM 명령과 떨어진 `systemd` 단위(`ltrun-<ID>`)로 돈다. Mac이 꺼져도 계속된다. 멈추려면 k6 서버에서 `systemctl stop ltrun-<ID>`(k6를 멈추고 결과를 올린 뒤 끝난다)

## 시나리오

```toml
name = "baseline"
repeat = 3                  # 라운드 수
reset_before_round = true   # 라운드마다 되돌리기(앱 정지 → Redis·DB 비우기 → 배포) + 시딩. 기본 true

[seed]                      # seed.sql 변수. 기본 creators 5, members 10000, start_balance 100, entry_hours 24, race_members 40, race_balance 11
members = 10000

[[steps]]
type = "k6"
name = "sustain"
script = "entry-sustain.js"
env = { RATE = "80", DURATION = "20m" }
```

| 단계 | 항목 | 내용 |
|---|---|---|
| `reset` | | 라운드 중간에 다시 되돌릴 때 |
| `seed` | | `[seed]` 값으로 시딩. `{admin_member_id}`·`{race_first_member_id}`를 남긴다 |
| `seed_closing` | `creator`(1), `minutes`(5) | 마감 이벤트. `{closing_event_id}`·`{end_at_ms}`를 남긴다 |
| `wait` | 하나만: `seconds`, `until_utc = "HH:MM[:SS]"`, `before_hour_minutes`, `before_end_seconds`, `event_closed = true`(+`timeout`) | 정각 N분 전, 마감 N초 전, 마감 처리까지 |
| `drain` | `timeout`(20m) | 응모 Stream 밀린 메시지 0까지 |
| `k6` | `name`, `script`, `env`, `args`, `monitor_seconds`(30), `hooks`, `stop_when`, `metrics`(true) | 아래 |
| `exec` | `on`, `run`, `timeout` | 명령 하나. 실패하면 실행이 멈춘다 |
| `verify` | | `verify.sh`(+마감 이벤트) + k6 쪽 대조(성공 건수 = DB 응모, 마감 1초 뒤 성공 0, 동시 요청 라운드) |

- `env`·`run`의 `{이름}`은 실행 변수로 바뀐다(`round`, `run_id`, 위 단계가 남긴 값, `before_hour_minutes` 뒤의 `hour_at`). 셸의 `${VAR}`는 그대로 둔다
- `k6` 감시: `monitor_seconds`마다 최근 구간 응모 수·초당·p95·실패·결과 코드와 Stream pending·lag(운영은 서버 대수)를 `timeline.log`에 남긴다
- `hooks = [{ after = "5m", on = "app", run = "docker restart cking-app" }]`: k6 시작 뒤 `after`에 명령을 따로 실행한다(부하는 계속). `on`은 `app`(첫 앱 서버), `apps`(전 서버), `k6`(k6 서버, k6 역할의 AWS 권한). 장애 주입에 쓴다
- `stop_when = { p95_ms = 1000, fail_pct = 1, lag_over = 20000, consecutive = 2 }`: 감시 구간에서 하나라도 넘는 일이 연속 `consecutive`번이면 k6를 멈춘다(한계 측정)
- k6 종료 코드 99(합격선 미달)·108(abortOnFail) 같은 결과는 측정값으로 기록하고 다음 단계로 간다. 시딩·SSM 실패 같은 실행기 오류는 그 자리에서 멈춘다
- 형식 검사: `python3 loadtest/runner/ltrun.py check loadtest/scenarios/*.toml`

| 시나리오 | 내용 |
|---|---|
| `smoke.toml` | 실행기 동작 확인(약 15분). 모든 단계 종류를 한 번씩 |
| `baseline.toml` | 기준선 3라운드: 예열 → 지속 80/s × 20분 → 마감 몰림 → 추첨 → 동시 요청 → 검증 |
| `closing-on-hour.toml` | 정각 5분 전 시작, 정각 마감 몰림(감시 10초) |
| `fault-app-restart.toml` | 지속 중 5분에 앱 재시작, 회복 시각 기록 |

## 결과

`s3://loadtest-cking-results-551372961758-ap-northeast-2-an/<대상>/<실행 ID>/`

- `results.md`: 커밋·이미지 태그·서버 크기, 단계별 시간·결과, k6 요약(응모 p50·p95·p99·실패·결과 코드), 단계 구간 지표 요약(서버 응모 p95, 서버 5xx, DB 반영 p95·1초 안 비율, 최대 밀린 메시지, Hikari 대기, 앱·k6 CPU 최대, 힙 최대, GC 정지), 훅, 검증
- `timeline.log`, `state.json`, `scenario.toml`, `k6/r<라운드>-<단계>.log`(요청별)·`.summary.json`·`.out.txt`·`.result.json`, `r<라운드>-verify.txt`
- 끝나면 개발 경보 Slack 채널(운영 대상은 운영 경보 채널)에 요약 숫자와 결과 위치만 보낸다. 요청별 기록은 버킷에만 둔다(이 저장소는 공개)
- 1년 뒤 지운다

## 권한

- k6 역할(`loadtest-cking-k6-role`): JWT 비밀값, `loadtest-cking-app` 이름표 서버에만 `AWS-RunShellScript`, 결과 버킷 `loadtest/`, Slack 웹훅 값
- 지표 요약은 `loadtest-cking-query` 역할로 넘어가 관측 서버 조회 문서(`dev-cking-observability-query`)만 보낸다. SendCommand는 인스턴스와 문서를 따로 허용하므로, k6 역할에 관측 서버를 넣으면 관측 서버에서도 임의 셸이 된다
- k6 역할은 앱 서버에서 root 명령을 실행할 수 있다. 부하 테스트 앱 서버는 측정 뒤 지우는 서버라 받아들인다. DB·Redis 비밀번호는 앱 서버 역할만 읽는다

## 남은 리소스 정리기

`envs/loadtest-base`의 `loadtest-cking-janitor`가 1시간마다 `cking:ttl-hours` 태그(`envs/loadtest`가 모든 리소스에 붙인다, 기본 12시간)가 있는 서버·RDS 중 켜진 지 그 시간이 지난 것을 **멈춘다**. 지우지 않아 state와 어긋나지 않는다. 멈추면 개발 경보 Slack 채널에 알린다. 다 썼으면 `lt.sh down`. 12시간보다 긴 측정이면 `-var ttl_hours=<시간>`으로 apply한다.

## 운영 대상

`lt.sh start <시나리오> prod`. 운영 DB를 지우므로 정식 오픈 전에만 쓴다. 되돌리기는 BE 문서 "운영 데이터 되돌리기"의 순서(그룹 자동 교체 정지 → 전 서버 앱 정지 → Redis·DB 비우기 → 한 대씩 배포 → 대상 healthy → 재개)를 실행기가 그대로 하고, 실패하면 그룹 자동 교체를 멈춘 채 둔다. 아직 실행해 보지 않았다. 운영 k6 역할(`prod-cking-k6-role`, `envs/prod-base`)에 더해야 하는 것:

- `ssm:SendCommand`: `AWS-RunShellScript` + 이름표 `aws:autoscaling:groupName = prod-cking-app` 서버
- `ssm:GetCommandInvocation`, `ec2:DescribeInstances`, `autoscaling:DescribeAutoScalingGroups`, `autoscaling:SuspendProcesses`·`ResumeProcesses`(prod-cking-app), `elasticloadbalancing:DescribeTargetGroups`·`DescribeTargetHealth`
- `sts:AssumeRole` → `loadtest-cking-query`(이미 운영 k6 역할을 믿는다), 결과 버킷 `prod/*` 쓰기·읽기와 목록(같은 계정이라 역할 정책만), `/cking/dev/monitoring/SLACK_PROD_ALERT_WEBHOOK_URL` 읽기
- 끝난 뒤 JWT_SECRET 교체(BE 문서 1·4·8단계)는 실행기가 하지 않는다
- 운영 API는 비밀 쿠키 게이트(WAF 차단 모드)가 있다. k6 요청에 `x-cking-gate` 헤더(`/cking/prod/GATE_SECRET`)를 붙여야 하고, k6 역할에 그 값 읽기 권한이 필요하다. BE `loadtest/*.js`는 아직 헤더를 보내지 않는다
