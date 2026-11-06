# 처리 실패 누적

> 전제: 개발 서버 1대(`dev-cking-app`), Docker Compose, Cking-BE `deploy.sh` 배포

`max by (stream) (cking_stream_pending_oldest_age_seconds) > 600`일 때. 앱 서버가 15초마다 Stream별로 PEL에서 가장 오래된 메시지가 만들어진 지 몇 초인지 기록한다.

## 뜻하는 것

읽었지만 ACK하지 못한 메시지 중 가장 오래된 것이 만들어진 지 10분이 넘었다. 처리에 실패한 메시지는 60초 뒤 PEL 회수(30초 주기)가 다시 처리하고, 전달 5회를 넘으면 Dead Stream으로 옮기며 ACK한다. 그래서 정상이면 늦어도 약 9분(회수 6번 × (60초 + 30초)) 안에 PEL에서 빠진다. 10분을 넘었다는 것은 PEL 회수가 돌지 않거나 Dead Stream 이동까지 실패하고 있다는 뜻이다. 구조는 [Redis Stream 공통](stream.md).

- 부하가 계속 들어오면 처리 중인 메시지가 늘 있어 PEL 건수는 0보다 크다. 그래서 건수가 아니라 나이로 본다(게임 데이에서 건수 기준이 평소 부하에 울렸다)
- 나이는 메시지가 만들어진 시각(Stream ID) 기준이다. 소비가 10분 넘게 밀리면 늦게 전달된 메시지가 처리되는 동안 잠깐 이 기준을 넘을 수 있다. 그때는 [Stream 밀림](cking-stream-lag.md)이 먼저 울린다
- 한 메시지만 실패하다 Dead Stream으로 옮겨지는 경우는 이 경보가 아니라 [Dead Stream 이동](cking-dead-stream.md)이 울린다

## 먼저 볼 곳

1. [상태 확인](stream.md#상태-확인)의 `XPENDING`: 몇 건인지, 전달 횟수
2. **크킹 로그**에서 레벨 `ERROR`, 검색어 `Stream`: 처리 실패 예외와 메시지 내용(`fields`)

## 원인별 대응

### 1. Dead Stream으로도 옮기지 못함

로그에 `Dead Stream으로 이관하지 못했습니다`(ERROR)가 같은 `sourceStreamId`로 반복된다. 예: Dead Stream 기록이 가리키는 회원이 없음(FK 위반). PEL에 남아 다음 회수에서 다시 시도된다.

→ BE 담당이 원인을 확인한다.

### 2. 모든 메시지가 실패 (DB·코드 문제)

여러 메시지가 같은 예외로 실패한다. 예: DB 연결 실패, 배포된 코드의 버그. DB가 끊기면 Dead Stream 기록도 DB에 남기지 못해 메시지가 PEL에 그대로 남는다.

- DB 문제면 [DB 연결 대기](cking-hikari-pending.md)
- 직전 배포 뒤 시작됐으면 이전 버전으로 되돌린다([배포 실패](deploy-failed.md#이전-버전으로-되돌리기)). 되돌리면 PEL 회수가 다시 처리한다

### 3. PEL 회수가 돌지 않음

로그에 해당 Stream의 처리 시도도, Dead Stream 이동도 없다. PEL 회수는 다른 정기 작업과 같은 공통 스케줄러에서 돈다. 앱이 살아 있는데 회수가 없으면 공통 스케줄러가 다른 작업에 막혔을 수 있다.

→ BE 담당에게 알린다. 앱을 재시작하면 회수가 다시 돈다.

## 해결 확인

`cking_stream_pending_oldest_age_seconds`가 600 아래로 내려간다. 5회 넘게 실패한 메시지는 Dead Stream으로 옮겨져 PEL에서 빠지므로 [Dead Stream 이동](cking-dead-stream.md)의 대응을 이어서 한다.

## 하면 안 되는 것

[공통](stream.md#공통으로-하면-안-되는-것)과 같다. 특히 pending을 `XACK`로 지우지 않는다.

## 운영에서 다른 점

- `XPENDING`은 [운영 상태 확인](stream.md#운영-상태-확인)으로 본다(감시용 사용자로는 안 된다)
- 되돌리기는 [운영 앱 배포](deploy-failed.md#운영-앱-배포-cking-be-deploy-to-prod)
