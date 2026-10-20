# 배포 실패

> 전제: 앱은 Cking-BE `cicd.yml` → S3 → SSM → 앱 서버 `deploy.sh`. 관측 설정·앱 서버 수집기는 이 저장소의 `deploy-observability.yml`, `deploy-app-agent.yml` → S3 → SSM → `apply.sh`

GitHub Actions에서 배포 워크플로가 실패했을 때.

## 앱 배포 (Cking-BE `Deploy to dev server`)

### 어느 단계에서 실패했는지 본다

| 실패 위치 | 서버 상태 | 대응 |
| --- | --- | --- |
| S3 업로드, SSM 전송 | 그대로(이전 버전) | 권한·AWS 상태 확인 뒤 재실행 |
| `deploy.sh [2/4]` Parameter Store 읽기 | 그대로 | 없는 파라미터를 등록하거나 코드에서 빼고 재배포 |
| `deploy.sh [3/4]` 이미지 pull | 그대로 | GHCR 상태 확인 뒤 재실행 |
| `deploy.sh [3/4]` compose `:?` 오류 | 그대로 | compose가 요구하는 값이 `deploy.sh`에 없음. BE PR로 맞춤 |
| `deploy.sh [4/4]` 헬스체크 실패 | **새 버전이 뜨지 못해 중단** | 바로 이전 버전으로 되돌리기 |
| 스모크 테스트 | 새 버전이 떠 있음, 일부 기능 이상 | 영향을 보고 되돌리기 판단 |

실패 로그는 Actions의 `배포 결과 확인` 단계에 `deploy.sh` 출력과 앱 로그 마지막 100줄로 남는다.

### 이전 버전으로 되돌리기

```bash
# 앱 서버 (root)
sudo docker images ghcr.io/ureca-cking/cking-be --format '{{.Tag}} {{.CreatedSince}}' | head
TAG=<되돌릴 태그>
sudo aws s3 cp "s3://dev-cking-deploy-551372961758/releases/$TAG/deploy.sh" /opt/cking/deploy.sh
sudo bash /opt/cking/deploy.sh "$TAG"
```

- 태그는 `<빌드 시각>-<커밋>` 형식이다. 마지막으로 정상이던 배포의 태그를 고른다
- 7일 안의 이미지는 서버에 남아 있어 pull 없이 바뀐다
- 되돌린 뒤 develop에 다음 커밋이 머지되면 그 버전이 다시 배포된다. 원인 수정 PR이 머지되기 전까지 팀에 알린다

### 하면 안 되는 것

- DB 마이그레이션(Flyway)이 포함된 배포를 되돌릴 때는 이전 코드가 새 스키마에서 도는지 먼저 확인한다. 이미 적용된 마이그레이션은 되돌려지지 않는다
- 서버에서 `docker compose up`을 직접 실행하지 않는다([앱 중단](cking-app-down.md#하면-안-되는-것))
- 관측 서버와 끊긴 동안에는 되돌리기 외의 앱 배포를 미룬다. 수집기가 아직 읽지 않은 로그가 컨테이너와 함께 지워진다([수집 대상 끊김](cking-target-down.md#하면-안-되는-것))

## 운영 앱 배포 (Cking-BE `Deploy to prod`)

`main` 머지 때 BE CI가 배포 파일을 운영 배포 버킷에 올리고 배포 태그(`/cking/prod/RELEASE_TAG`)를 바꾼 뒤 서버 교체를 시작한다. 새 서버는 같은 태그의 `smoke.js`로 자기 자신을 검사해 통과해야 요청을 받는다.

| 실패 지점 | 그때 상태 | 자동으로 되는 것 |
| --- | --- | --- |
| 서버 교체 실패(새 서버가 검사에서 버려짐 등) | 옛 서버가 남는다. 일부 서버만 바뀌었을 수 있다 | 교체 취소 → 배포 태그 되돌림 → 바뀐 서버가 남아 있으면 이전 태그로 다시 교체(`scripts/prod-recover.sh`) |
| 교체 뒤 ALB 경로 스모크 실패 | 새 버전이 모든 요청을 받는 중 | 이전 태그로 한 번 자동 교체하고 다시 검사 |
| 첫 배포 | 이전 태그가 없다 | 되돌리지 않는다 |

자동 되돌리기가 실패했거나 스모크가 잡지 못한 문제는 수동으로 되돌린다: Cking-BE Actions → `Deploy to prod` → `Run workflow`(`main`) → `image_tag`에 마지막으로 정상이던 태그. 같은 교체·자기 검사·스모크를 거친다.

```bash
# Mac: 운영에 올렸던 태그 목록
aws s3 ls s3://prod-cking-deploy-551372961758-ap-northeast-2-an/releases/
```

### 운영에서 하면 안 되는 것

- 보안 수정이 들어간 배포보다 앞선 태그로 되돌리지 않는다. 고친 취약점이 다시 열린다. 그 경우는 원인 수정을 배포한다
- DB 마이그레이션 호환은 개발과 같다. 이전 코드가 지금 스키마에서 도는지 먼저 확인한다
- 서버에서 `deploy.sh`를 직접 실행해 한 서버만 바꾸지 않는다. 서버마다 버전이 달라지고, 서버 그룹이 새로 띄우는 서버는 배포 태그를 따른다
- 되돌린 뒤 `main`에 다음 커밋이 머지되면 그 버전이 다시 배포된다. 원인 수정이 머지되기 전까지 `main` 머지를 멈추도록 팀에 알린다. 배포는 한 번에 하나만 돌고 기다리는 자리는 하나라, 되돌리기를 기다리는 동안 `main` 배포가 들어오면 되돌리기가 취소(`cancelled`)된다. 그때는 다시 실행한다

## 관측 설정·앱 서버 수집기 배포 (이 저장소)

- 실패 로그는 `관측 서버에 적용`·`앱 서버에 적용` 단계에 `apply.sh` 출력으로 남는다
- `apply.sh`는 바뀐 컨테이너만 다시 만든다. 실패하면 일부 컨테이너만 새 설정일 수 있다. 출력의 `docker compose ps`로 상태를 본다
- 설정 오류면 고치는 PR을 머지하거나, 되돌리는 PR(`git revert`)을 머지한다. 머지하면 다시 배포된다
- 일시적 오류(이미지 pull, SSM)면 Actions에서 Re-run 또는 Run workflow

### 하면 안 되는 것

- 서버에서 설정 파일을 직접 고치지 않는다. 다음 배포에서 덮어써지고 저장소와 어긋난다
- 관측 서버와 끊긴 상태에서 앱 서버 수집기 배포를 재실행하지 않는다. 수집기가 재시작돼 쌓아 둔 로그를 잃는다([수집 대상 끊김](cking-target-down.md#하면-안-되는-것))
