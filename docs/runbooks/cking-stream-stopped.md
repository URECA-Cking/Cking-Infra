# Stream 소비 멈춤

> 전제: 개발 서버 1대(`dev-cking-app`), Docker Compose, Cking-BE `deploy.sh` 배포

`max by (stream) (redis_stream_group_consumer_idle_seconds) > 120`이 1분 지속될 때. 급함(`@channel`).

## 뜻하는 것

앱의 소비자가 2분 넘게 Stream을 읽으러 오지 않았다. 응모·적립 요청은 성공하지만 DB에 반영되지 않는다. 구조는 [Redis Stream 공통](stream.md).

평소 idle은 2초 이하, 7일 최대 37초(앱 재시작 중)다.

소비자가 읽기를 멈춰도 Redis의 소비자 목록은 남으므로 소비자 수가 아니라 idle로 판단한다.

## 먼저 볼 곳

1. **크킹 서비스 개요 → 수집 대상, 앱 가동 시간**: 앱이 죽었으면 [앱 중단](cking-app-down.md)이 원인이다
2. 어느 Stream인지 경보 라벨 `stream`으로 확인하고 [상태 확인](stream.md#상태-확인)
3. 앱 로그: **크킹 로그**에서 검색어 `Stream`, 레벨 `ERROR`·`WARN`

## 원인별 대응

### 1. 앱이 멈췄거나 재시작 중

[앱 중단](cking-app-down.md)을 따른다. 앱이 다시 뜨면 소비자가 마지막 위치부터 이어 읽는다.

### 2. 앱은 살아 있는데 리스너만 멈춤

로그에 Redis 연결 오류(`Connection closed`, `NOGROUP`) 뒤 재개 로그가 없다.

- `NOGROUP`: 소비자 그룹이 사라졌다(Redis 데이터 유실 등). 앱이 그룹을 다시 만들고 이어 읽도록 되어 있으므로 1~2분 지켜본다
- 그래도 idle이 계속 오르면 앱을 재시작한다. 메시지는 Stream과 PEL에 남아 있어 재시작으로 잃지 않는다

```bash
# 앱 서버
sudo docker restart cking-app
```

재시작 뒤 idle이 2초 이하로 돌아오고 lag가 줄어드는지 본다. 원인(로그)은 BE 이슈로 남긴다.

### 3. Redis가 멈춤

`sudo docker ps --filter name=cking-redis`가 멈춤이면 `sudo docker start cking-redis`. 이때 응모도 실패하고 있었다.

## 하면 안 되는 것

[공통](stream.md#공통으로-하면-안-되는-것)과 같다.
