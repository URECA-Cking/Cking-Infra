# Dead Stream 이동

> 전제: 개발 서버 1대(`dev-cking-app`), Docker Compose, Cking-BE `deploy.sh` 배포

5분 안에 앱 로그 `Dead Stream으로 이동했습니다`가 1건 이상일 때(Loki).

## 뜻하는 것

처리에 5회 넘게 실패한 메시지가 Stream에서 MySQL `dead_stream_message`로 옮겨졌다. 그 응모·적립은 DB에 반영되지 않은 상태로 보관 중이다. 사용자 화면의 잔액(Redis)과 DB 기록이 어긋난다. 구조는 [Redis Stream 공통](stream.md).

## 먼저 볼 곳

1. **크킹 로그**에서 검색어 `Dead Stream`: `sourceStreamId`, `fields`(어떤 회원·이벤트·금액)
2. 같은 메시지의 이전 실패 로그(레벨 `ERROR`): 실패 원인
3. 관리자 API로 목록 확인: `GET /api/admin/dead-streams` (기본 `UNRESOLVED`)

## 대응

1. 실패 원인을 고친다(BE 수정·배포, 또는 데이터 정정)
2. 고친 뒤 관리자 API로 다시 적용한다: `POST /api/admin/dead-streams/{id}/replay`. 보존된 원본으로 다시 처리하고 `RESOLVED`로 표시한다. 이미 `RESOLVED`면 다시 적용하지 않는다
3. 목록에 `UNRESOLVED`가 남지 않았는지 확인한다

로그에 `Dead Stream으로 이관하지 못했습니다`(ERROR)가 있으면 옮기기 자체가 실패한 것이다. 메시지는 PEL에 남아 30초마다 다시 시도된다. 로그의 예외(예: `dead_stream_message` FK 위반)를 BE 담당이 확인한다.

## 하면 안 되는 것

- 원인을 고치기 전에 replay하지 않는다. 같은 이유로 다시 실패한다
- `dead_stream_message`를 DB에서 직접 지우거나 고치지 않는다. 반영되지 않은 응모·적립의 유일한 기록이다
