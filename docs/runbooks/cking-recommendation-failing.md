# 추천 배치 실패 반복

> 전제: [개발 추천 배치 서버](recommendation-batch.md)의 전제와 같다. 1분 확인은 실행이 끝나고 60초 뒤 다시 돈다. 같은 입력의 공급자 호출은 최대 3번

10분 안에 실패 알림 로그(`{instance="dev-cking-recommendation", unit=~"cking-content-alert@.*", level="error"}`)가 3건 이상일 때(Loki).

## 뜻하는 것

작업자 실행이 연달아 실패했다. 실행이 실패할 때마다 실패 알림 유닛이 로그 1줄을 남긴다. 실패한 크리에이터의 콘텐츠 태그·추천은 BE에 반영되지 않고, 이미 반영된 결과는 그대로 보인다.

한두 번은 평소에도 난다. 공급자 응답이 검증에 걸리면 다음 실행에서 다시 호출하고, BE가 배포로 재시작하면 그 사이 실행 1번이 실패한다(2026-10-22 개발: 첫 실행의 `PROVIDER_FAILURE` 1번은 다음 실행에서 성공, BE 배포 중 `BACKEND_REQUEST_FAILED` 1번). 같은 입력이 3번 실패하면 그 뒤로는 실행마다 `FINAL_PROVIDER_FAILURE`로 실패해 경보가 계속 울린다.

## 먼저 볼 곳

Grafana Explore(Loki)에서 작업자가 남긴 실패 코드를 본다.

```text
{instance="dev-cking-recommendation", unit=~"cking-content-(event|daily).service"} |= "content-worker:"
```

`content-worker: partial failure (<코드>)`는 일부 크리에이터만, `content-worker: failed (<코드>)`는 실행 전체가 실패한 것이다. 크리에이터별 코드는 서버의 `/var/lib/cking-content/summary.json`(`stages.tags.rows[].code`)에 있다. 접속은 [개발 추천 배치 서버](recommendation-batch.md#먼저-볼-곳)를 따른다.

## 원인별 대응

- `BACKEND_REQUEST_FAILED`: BE에 닿지 못했거나 5xx를 받았다. BE 배포 중이면 끝나고 풀린다. 계속되면 [앱 중단](cking-app-down.md) 경보와 BE 로그를 본다
- `BACKEND_AUTHORIZATION_FAILED`: BE가 배치 키를 거절했다(401/403). 배치의 `CKING_CONTENT_TAG_ACCESS_TOKEN`·`CKING_RECOMMENDATION_API_KEY`와 BE의 해시(`/cking/dev/CKING_CONTENT_TAG_TOKEN_HASH`, `/cking/dev/CKING_RECOMMENDATION_API_KEY_HASHES`)가 짝이 맞는지 본다. 값을 바꿨다면 BE는 재배포, 배치는 서버 교체가 있어야 반영된다
- `PROVIDER_FAILURE`: 공급자(OpenAI) 호출이나 응답 검증이 실패했다. 다음 실행에서 다시 호출한다. 계속되면 공급자 상태와 지출 한도(OpenAI 월 $15)를 본다
- `FINAL_PROVIDER_FAILURE`: 같은 입력이 3번 실패했다. 원인을 해결한 뒤 [콘텐츠 작업자 운영](https://github.com/URECA-Cking/Cking-LLM-Benchmark/blob/develop/docs/guides/content-worker.md)의 수동 재시도 절차를 따른다
- `DAILY_BUDGET_EXHAUSTED`: 하루 호출 상한(`CKING_TAG_DAILY_CALLS`, 100번)을 다 썼다. UTC 자정(한국 09:00)에 풀린다. 개발 크리에이터 수(11명)에 비해 많이 쓴 것이므로 같은 입력을 반복 호출하는지 `budget-<날짜>.json`과 `records/*/attempts.json`부터 본다
- `TAXONOMY_NOT_APPROVED`, `CONFIGURATION_MISMATCH`: BE에 등록된 taxonomy·생성 설정 해시가 배포 패키지와 다르다. 패키지를 새로 배포했다면 CI 요약의 `configHash`와 BE `creator_content_taxonomy`를 비교하고, 바뀌었으면 승인을 받아 새로 등록한다
- `INPUT_REFRESH_REQUIRED`: 처리 중 소개가 바뀌어 BE가 409를 돌려줬다. 다음 실행이 입력을 다시 읽는다. `PERSISTENT_INPUT_CONFLICT`로 넘어가면 작업자 운영 문서의 409 복구 절차를 따른다
- `RECOMMENDATION_FAILED`: 태그 다음 단계인 추천 계산·적재가 실패했다. 임베딩 공급자(DeepInfra) 상태와 지출 한도(월 $5)를 본다
- `WORKER_STARTUP_FAILED`: 환경 파일이나 패키지 문제다. 서버의 부팅 로그(`/var/log/cloud-init-output.log`)를 본다

## 하면 안 되는 것

- 실패를 없애려고 상태 디스크의 기록(`records/`, `budget-*.json`, `models*.json`)을 지우지 않는다. 같은 입력을 다시 호출해 비용이 들고 BE 적재 기록과 갈라진다
- 원인을 보기 전에 하루 호출 상한을 올리지 않는다

## 운영에서 다른 점

- 운영 추천 배치 서버를 만들 때 운영 규칙을 추가한다
