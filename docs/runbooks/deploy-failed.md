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

## 관측 설정·앱 서버 수집기 배포 (이 저장소)

- 실패 로그는 `관측 서버에 적용`·`앱 서버에 적용` 단계에 `apply.sh` 출력으로 남는다
- `apply.sh`는 바뀐 컨테이너만 다시 만든다. 실패하면 일부 컨테이너만 새 설정일 수 있다. 출력의 `docker compose ps`로 상태를 본다
- 설정 오류면 고치는 PR을 머지하거나, 되돌리는 PR(`git revert`)을 머지한다. 머지하면 다시 배포된다
- 일시적 오류(이미지 pull, SSM)면 Actions에서 Re-run 또는 Run workflow

### 하면 안 되는 것

- 서버에서 설정 파일을 직접 고치지 않는다. 다음 배포에서 덮어써지고 저장소와 어긋난다
- 관측 서버와 끊긴 상태에서 앱 서버 수집기 배포를 재실행하지 않는다. 수집기가 재시작돼 쌓아 둔 로그를 잃는다([수집 대상 끊김](cking-target-down.md#하면-안-되는-것))
