# 개발 추천 배치 서버

> 전제: 서버 그룹 `dev-cking-recommendation`(1대, t4g.small 스팟, 2a), 상태 디스크 `dev-cking-recommendation-state`(`/var/lib/cking-content`), 배포 버전 `/cking/dev-recommendation/RELEASE`, 콘텐츠 작업자 타이머 `cking-content-event.timer`(1분)·`cking-content-daily.timer`(03:00). 작업자 동작과 복구는 [콘텐츠 작업자 운영](https://github.com/URECA-Cking/Cking-LLM-Benchmark/blob/develop/docs/guides/content-worker.md)

경보와 연결된 절차가 아니다. 서버를 처음 띄울 때, 값을 넣거나 바꿀 때, 작업자가 돌지 않을 때 쓴다.

## 뜻하는 것

배포는 서버 교체다. 새 서버는 시작 대기(Pending:Wait)에서 상태 디스크를 붙이고 배포 버전의 패키지(Python 3.12 포함)를 설치한 뒤에야 들어온다. 실패하거나 900초가 지나면 버려지고 그룹이 새 서버를 띄운다. 스팟이 중단돼도 같은 과정으로 새 서버가 뜬다. 수집기 설정(`app-agent/`)이 바뀌어도 Infra 수집기 배포 워크플로가 서버를 교체한다.

환경 파일(`/etc/cking/content-worker.env`)은 부팅 때 `/cking/dev-recommendation/`에서 만든다. 값 6개(`CKING_BE_URL`, `CKING_CONTENT_TAG_ACCESS_TOKEN`, `CKING_RECOMMENDATION_API_KEY`, `OPENAI_API_KEY`, `DEEPINFRA_API_KEY`, `CKING_TAG_DAILY_CALLS`)가 모두 있어야 타이머를 켠다. 빠진 값이 있으면 서버는 들어오고 타이머만 꺼져 있다. `CKING_BE_URL`과 `CKING_TAG_DAILY_CALLS`는 Terraform이 만든다.

## 처음 띄울 때와 값을 바꿀 때

1. 배포 버전이 있어야 한다. 추천 배치 저장소 develop CI가 첫 패키지를 올리면 생긴다. 없으면 새 서버가 시작 대기에서 계속 버려진다
2. `envs/dev` apply
3. 비밀값 4개를 SecureString으로 넣는다(값은 화면에 남기지 않는다)
4. 서버를 교체해 환경 파일을 다시 만든다

```bash
# Mac: 서버 교체와 진행 확인
aws autoscaling start-instance-refresh --region ap-northeast-2 --auto-scaling-group-name dev-cking-recommendation \
  --preferences '{"MinHealthyPercentage":0}'
aws autoscaling describe-instance-refreshes --region ap-northeast-2 --auto-scaling-group-name dev-cking-recommendation \
  --max-records 1 --query 'InstanceRefreshes[0].[Status,StatusReason]' --output text
```

## 먼저 볼 곳

```bash
# Mac: 서버 그룹 활동. 시작 대기에서 버려진 서버, 스팟 중단으로 바뀐 서버가 여기 남는다
aws autoscaling describe-scaling-activities --region ap-northeast-2 --auto-scaling-group-name dev-cking-recommendation \
  --max-items 10 --query 'Activities[].[StartTime,StatusCode,Description,Cause]' --output table
```

```bash
# 추천 배치 서버(SSM 세션, 인스턴스 이름표 dev-cking-recommendation)
systemctl list-timers 'cking-content-*'
cat /opt/cking-llm/RELEASE
sudo cat /var/lib/cking-content/last-success.json
sudo journalctl -u cking-content-event.service --since -1h --no-pager | tail -20
sudo tail -50 /var/log/cloud-init-output.log
```

Grafana Explore(Loki)에서 작업자 로그는 `{instance="dev-cking-recommendation", container="journal"}`, 실패 알림은 `{instance="dev-cking-recommendation", unit=~"cking-content-alert@.*"}`로 본다.

## 원인별 대응

- **서버가 계속 버려짐**(활동에 시작 대기 실패가 반복): 버려진 서버는 곧 종료돼 들어갈 수 없다. 부팅 출력은 EC2 콘솔 출력(`aws ec2 get-console-output --region ap-northeast-2 --instance-id <서버> --output text`, 종료 때도 올라온다)으로 본다. 흔한 원인은 배포 버전 값이나 그 패키지(`s3://dev-cking-deploy-551372961758/recommendation/releases/<버전>/`)가 없는 것, 상태 디스크가 다른 서버에 붙어 있는 것이다
- **스팟 중단**: 활동의 `Cause`에 중단이 적혀 있다. 새 서버가 디스크를 다시 붙이고 이어서 돈다. 처리 중이던 작업은 lease(900초)가 끝나면 BE가 다시 넘긴다
- **타이머가 꺼져 있음**: 부팅 로그에 `추천 배치 값이 n/6개만 있어 타이머를 켜지 않는다`가 있다. 빠진 값을 넣고 서버를 교체한다
- **작업자가 실패함**(`last-success.json`이 오래됨, 실패 알림 로그): `/var/lib/cking-content/summary.json`의 `code`로 [콘텐츠 작업자 운영](https://github.com/URECA-Cking/Cking-LLM-Benchmark/blob/develop/docs/guides/content-worker.md)의 복구 절차를 따른다

## 하면 안 되는 것

- 상태 디스크를 지우거나 다른 서버에 붙이지 않는다. 작업자는 상태 폴더 하나·서버 하나만 지원한다. 잃으면 작업자 운영 문서의 복구 절차(BE의 최대 applicationSequence와 결과 세대 확인부터)를 따라야 한다
- 그룹의 서버 수를 2 이상으로 늘리지 않는다. 같은 이유로 작업자가 둘이 되면 안 된다
