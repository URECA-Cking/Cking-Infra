# 처리 실패 누적

> 전제: 개발 서버 1대(`dev-cking-app`), Docker Compose, Cking-BE `deploy.sh` 배포

`max by (stream) (redis_stream_group_messages_pending) > 0`이 10분 지속될 때.

## 뜻하는 것

읽었지만 ACK하지 못한 메시지가 10분째 남아 있다. PEL 회수 스케줄러가 30초마다 다시 처리하는데도 계속 실패하고 있다. 7일 최대값은 0이다. 구조는 [Redis Stream 공통](stream.md).

전달 5회를 넘으면 Dead Stream으로 옮겨지므로, 그대로 두면 [Dead Stream 이동](cking-dead-stream.md)이 이어서 울린다.

## 먼저 볼 곳

1. [상태 확인](stream.md#상태-확인)의 `XPENDING`: 몇 건인지, 전달 횟수
2. **크킹 로그**에서 레벨 `ERROR`, 검색어 `Stream`: 처리 실패 예외와 메시지 내용(`fields`)

## 원인별 대응

### 1. 특정 메시지만 실패 (데이터 문제)

같은 `sourceStreamId`가 반복된다. 예: 없는 회원·이벤트를 가리킴(FK 위반), 잘못된 값.

→ 5회 뒤 Dead Stream으로 옮겨지는 것이 정상 흐름이다. BE 담당이 원인을 확인한다.

### 2. 모든 메시지가 실패 (DB·코드 문제)

여러 메시지가 같은 예외로 실패한다. 예: DB 연결 실패, 배포된 코드의 버그.

- DB 문제면 [DB 연결 대기](cking-hikari-pending.md)
- 직전 배포 뒤 시작됐으면 이전 버전으로 되돌린다([배포 실패](deploy-failed.md#이전-버전으로-되돌리기)). 되돌리면 PEL 회수가 다시 처리한다
- 원인을 고치기 전에는 메시지가 하나씩 Dead Stream으로 옮겨진다. Dead Stream 메시지는 고친 뒤 다시 적용할 수 있다

## 하면 안 되는 것

[공통](stream.md#공통으로-하면-안-되는-것)과 같다. 특히 pending을 `XACK`로 지우지 않는다.

## 운영에서 다른 점

- `XPENDING`은 [운영 상태 확인](stream.md#운영-상태-확인)으로 본다(감시용 사용자로는 안 된다)
- 되돌리기는 [운영 앱 배포](deploy-failed.md#운영-앱-배포-cking-be-deploy-to-prod)
