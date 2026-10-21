# 댓글 필터 차단·해제

> 전제: 필터 Lambda `dev-cking-comment-filter`(운영은 `prod-cking-comment-filter`), 함수 URL IAM 인증, 예약 동시성 없음. BE는 판정을 비동기로 요청하고, 실패하면 1·2·4·8분 간격으로 최대 5번 다시 요청한다

경보와 연결된 절차가 아니다. 필터 판정이 잘못되거나(멀쩡한 댓글이 BLOCK) 필터 호출을 멈춰야 할 때 쓴다.

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
# Mac: 해제
aws lambda delete-function-concurrency --region ap-northeast-2 --function-name <env>-cking-comment-filter
```

- 차단 중 BE는 판정 실패(`httpStatus=429`)로 기록하고 다시 요청한다. 재요청 간격이 늘어나므로 차단이 약 15분을 넘으면 그동안 쓴 댓글은 재요청을 다 써서, 해제한 뒤에도 판정하지 않은 채(보이는 상태로) 남는다
- 이미 BLOCK된 댓글은 차단해도 그대로 숨겨져 있다
- 2026-10-21 개발에서 확인: 차단 직후 호출 429(0.08초), 해제 직후 200

## 콜드 스타트 확인

```bash
# Mac: 최근 1시간 호출 기록. Init Duration이 있는 줄이 콜드 스타트다
aws logs filter-log-events --region ap-northeast-2 --log-group-name /aws/lambda/<env>-cking-comment-filter \
  --start-time $(( ($(date +%s) - 3600) * 1000 )) --filter-pattern REPORT --query 'events[].message' --output text
```

- 콜드 스타트 중 `Status: timeout`이면 기동이 실행 상한(120초)보다 오래 걸린 것이다. 상한에 걸리면 기동을 처음부터 다시 하므로 상한을 늘린다
- 2026-10-21 개발 측정: 새 실행 환경 53.5초(초기화 9.8초 + 첫 호출 43.2초), 같은 호스트에 이미지가 캐시돼 있으면 6.7초, 따뜻할 때 판정 97~118ms, 최대 메모리 933MB. 새 이미지의 첫 기동은 30초 상한에서 6번 다시 시작해 약 3분 반 걸렸다

## 하면 안 되는 것

- 차단 중에 그 환경을 `terraform apply`하지 않는다. 예약 동시성을 코드에 두지 않았으므로 apply가 차단을 푼다(plan에 `reserved_concurrent_executions = 0 -> -1`)
- 콜드 스타트 timeout을 보고 실행 상한을 줄이지 않는다. 기동이 끝나지 못하고 되풀이된다
