# 댓글 필터 차단·해제

> 전제: 필터 Lambda `dev-cking-comment-filter`(운영은 `prod-cking-comment-filter`), 함수 URL IAM 인증, 예약 동시성 개발 2·운영 8(BE 판정 스레드 2개 × 앱 서버 개발 1대·운영 최대 4대). BE는 판정을 비동기로 요청하고(응답 대기 30초, 판정 스레드 2개·대기열 100), 실패하면 1·2·4·8분 간격으로 최대 5번 다시 요청한다

필터 판정이 잘못되거나(멀쩡한 댓글이 BLOCK) 필터 호출을 멈춰야 할 때 쓴다. 경보 [댓글 필터 호출 실패 지속](cking-comment-filter-failing.md)·[댓글 판정 대기열 쌓임](cking-comment-filter-queue.md)이 함께 보는 확인 방법도 여기에 둔다.

## 뜻하는 것

판정이 실패해도 댓글은 그대로 보인다. 숨겨지는 것은 마지막 판정이 BLOCK인 댓글과 관리자가 숨긴 댓글뿐이다. 필터를 막는 것은 판정을 멈추고 새 댓글을 모두 보이게 두는 것이다.

| 방법 | 반영 | 쓰는 때 |
| --- | --- | --- |
| Lambda 예약 동시성 0 | 몇 초 | 판정을 바로 멈춰야 할 때 |
| Parameter Store `COMMENT_FILTER_ENABLED=false` + BE 재배포(운영) | BE 서버 교체가 끝난 뒤 | 운영에서 필터를 한동안 끌 때 |

Parameter Store 값은 BE 배포 때 `deploy.sh`가 읽는다. 값만 바꾸면 실행 중인 BE에는 반영되지 않는다. 운영 재배포는 Cking-BE `Deploy to prod`를 지금 배포된 태그(`/cking/prod/RELEASE_TAG`)로 수동 실행한다. 새 서버가 부팅하며 값을 다시 읽는다. 개발은 필터를 저장소(`application-dev.yml`)에서 켠다.

## 즉시 차단·해제

```bash
# Mac: 차단. 모든 호출이 429로 거절된다
aws lambda put-function-concurrency --region ap-northeast-2 --function-name <env>-cking-comment-filter --reserved-concurrent-executions 0
# Mac: 해제. 코드의 예약 동시성(개발 2, 운영 8)으로 되돌린다
aws lambda put-function-concurrency --region ap-northeast-2 --function-name dev-cking-comment-filter --reserved-concurrent-executions 2
aws lambda put-function-concurrency --region ap-northeast-2 --function-name prod-cking-comment-filter --reserved-concurrent-executions 8
```

- 차단 중 BE는 판정 실패(`httpStatus=429`)로 기록하고 다시 요청한다. 재요청 간격이 늘어나므로 차단이 약 15분을 넘으면 그동안 쓴 댓글은 재요청을 다 써서, 해제한 뒤에도 판정하지 않은 채(보이는 상태로) 남는다
- 이미 BLOCK된 댓글은 차단해도 그대로 숨겨져 있다
- 2026-10-22 개발에서 확인: 차단 뒤 0.2초 호출은 아직 200, 1.4초 호출부터 429(0.07초). 예약 동시성 2로 해제한 직후(0.2초) 200

## 운영 이미지 배포·되돌리기

운영 Lambda 이미지는 필터 저장소 `main` 머지 때 CI가 바꾼다. 개발 CI가 확인하고 올린 이미지 중 이미지에 들어가는 파일이 main과 같은 커밋의 이미지에 `prod-<main 커밋>` 태그를 붙여 운영 Lambda로 바꾸고, 함수 URL을 호출해 확인한다. 확인에 실패하면 이전 이미지로 되돌린다. 그런 이미지가 없으면(develop의 개발 배포가 끝나기 전에 합친 경우) 올리지 않는다.

수동 되돌리기는 필터 저장소 Actions에서 예전 `prod-` 태그로 직접 실행한다. ECR은 `prod-` 태그 이미지를 최근 10개 남긴다(`envs/dev/comment_filter.tf`).

## 판정 상태 보기

Grafana(`https://dev-monitoring.cking.co.kr`) → Explore. 운영은 `instance="dev-cking-app"`을 `instance=~"prod-cking-app.*"`로 바꾼다.

- 판정·실패 로그(Loki):
  ```
  {instance="dev-cking-app", container="app"} |~ "댓글 필터|필터 서비스"
  ```
- BE가 필터 응답을 기다린 시간 p95, 1시간(Loki):
  ```
  quantile_over_time(0.95, {instance="dev-cking-app", container="app"} |= "판정을 저장했습니다" | regexp "latencyMs=(?P<latency>[0-9]+)" | unwrap latency [1h])
  ```
- 시간 초과 횟수, 1시간(Loki):
  ```
  sum(count_over_time({instance="dev-cking-app", container="app"} |= "failureKind=TIMEOUT" [1h]))
  ```
- 판정 대기열과 처리 중인 스레드(Prometheus): `executor_queued_tasks{instance="dev-cking-app", name="commentFilterExecutor"}`, `executor_active_threads{instance="dev-cking-app", name="commentFilterExecutor"}`. 스레드는 2개, 대기열은 100이다
- 재시도 제출·상한 도달·대기열 가득 참, 1시간(Prometheus): `increase(comment_filter_retry_attempted_total{instance="dev-cking-app"}[1h])`. `_exhausted_total`, `_queue_full_total`도 같은 형식이다. BE가 다시 시작하면 카운터는 0부터 센다
- 2026-10-21 개발: 따뜻할 때 BE 대기 0.1~0.8초. 응답 대기가 5초일 때는 쉬고 난 뒤 첫 판정이 콜드 스타트 때문에 시간 초과되고 1분 뒤 재시도에서 저장됐다(URECA-Cking/Cking-BE#726에서 30초로 늘림). 필터를 켤 때 쌓여 있던 판정을 처리하며 대기열은 최대 17건까지 찼다가 몇 초 안에 비었다

## 콜드 스타트 확인

```bash
# Mac: 최근 1시간 호출 기록. Init Duration이 있는 줄이 콜드 스타트다
aws logs filter-log-events --region ap-northeast-2 --log-group-name /aws/lambda/<env>-cking-comment-filter \
  --start-time $(( ($(date +%s) - 3600) * 1000 )) --filter-pattern REPORT --query 'events[].message' --output text
```

CloudWatch → Logs Insights에서 로그 그룹 `/aws/lambda/<env>-cking-comment-filter`를 고르면 30분 단위 요약을 볼 수 있다.

```
filter @type = "REPORT"
| stats count() as calls, count(@initDuration) as cold_starts, avg(@duration) as avg_ms, pct(@duration, 95) as p95_ms, max(@duration) as max_ms, max(@maxMemoryUsed) / 1000000 as max_mem_mb by bin(30m)
```

- 콜드 스타트 중 `Status: timeout`이면 기동이 실행 상한(120초)보다 오래 걸린 것이다. 상한에 걸리면 기동을 처음부터 다시 하므로 상한을 늘린다
- 2026-10-21 개발 측정: 새 실행 환경 53.5초(초기화 9.8초 + 첫 호출 43.2초), 같은 호스트에 이미지가 캐시돼 있으면 6.7초, 따뜻할 때 판정 97~118ms, 최대 메모리 933MB. 새 이미지의 첫 기동은 30초 상한에서 6번 다시 시작해 약 3분 반 걸렸다

## 하면 안 되는 것

- 차단 중에 그 환경을 `terraform apply`하지 않는다. apply가 예약 동시성을 코드 값으로 되돌려 차단을 푼다(plan에 `reserved_concurrent_executions = 0 -> 2`, 운영 `0 -> 8`)
- 해제에 `delete-function-concurrency`를 쓰지 않는다. 예약이 지워져 다음 apply 전까지 그 Lambda가 개발·운영이 같이 쓰는 계정 동시성을 제한 없이 쓴다
- 콜드 스타트 timeout을 보고 실행 상한을 줄이지 않는다. 기동이 끝나지 못하고 되풀이된다
