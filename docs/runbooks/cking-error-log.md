# ERROR 로그

> 전제: 개발 서버 1대(`dev-cking-app`), Docker Compose, Cking-BE `deploy.sh` 배포

`increase(logback_events_total{level="error"}[5m]) > 0`일 때.

## 뜻하는 것

앱이 ERROR 로그를 남겼다. 7일 6건이었고 모두 실제 문제였다(2026-10-13 Redis 재시작 때 Stream 오류). 마감 지연도 ERROR로 남는다.

## 먼저 볼 곳

**크킹 로그**에서 레벨 `ERROR`, 경보 시각 앞뒤. 같은 시각에 다른 경보가 울렸는지 본다.

## 대응

- 다른 경보와 함께 울렸으면 그 경보의 런북을 따른다
- 단독이면 로그 내용으로 판단한다
  - Stream·Dead Stream 관련 → [Redis Stream 공통](stream.md)
  - 마감·추첨 관련 → 이벤트 담당에게 알린다. 마감이 늦으면 추첨 스냅샷 시점이 밀린다
  - 그 밖 → 예외와 스택 트레이스로 BE 이슈를 만든다
- 반복되는 ERROR가 실제 문제가 아니면 로그 레벨을 낮추는 BE PR을 만든다. 경보 기준을 올리지 않는다

## 하면 안 되는 것

- 원인을 확인하지 않고 경보를 묵음(silence) 처리하지 않는다. 묵음은 원인을 알고 고치는 동안만 쓴다
