# 이미지 파이프라인 DLQ 쌓임

> 전제: 브라우저가 업로드 버킷 `raw/<최종 키>`에 올리면 S3 이벤트 → 작업 큐 `dev-cking-image-jobs` → 정규화 Lambda `dev-cking-image-normalizer` → 최종 키 저장 → 결과 큐 `dev-cking-image-results` → 앱이 업로드 기록을 완료로 바꾼다. 원본은 1일 뒤 지워진다

> 이름은 개발 기준이다. 운영은 앞의 `dev-`를 `prod-`로 바꾼다(큐·함수·로그 그룹·경보)

작업 DLQ(`dev-cking-image-jobs-dlq`)나 결과 DLQ(`dev-cking-image-results-dlq`)에 메시지가 1개 이상일 때(CloudWatch).

## 뜻하는 것

- **작업 DLQ:** Lambda가 같은 원본을 3번 처리하지 못했다. 이미지가 규칙에 맞지 않는 경우(형식, 크기, 해상도)는 실패가 아니라 FAILED 결과로 끝나므로 여기 오지 않는다. 권한, 결과 큐 전송, 메모리·시간 초과 같은 처리 오류다. 그 업로드는 PENDING으로 남고 브라우저는 처리 대기 시간을 넘겨 실패로 보여 준다
- **결과 DLQ:** 앱이 결과 메시지를 5번 받아도 처리하지 못했다. DB 연결 실패 같은 앱 오류다. 최종 키에 이미지는 있지만 업로드는 완료로 바뀌지 않는다. 업로드 기록이 없는 키의 결과는 앱이 경고 로그만 남기고 메시지를 지우므로 여기 오지 않는다

## 먼저 볼 곳

```bash
# Mac: DLQ 메시지 내용(지우지 않음)
aws sqs receive-message --queue-url "$(aws sqs get-queue-url --queue-name dev-cking-image-jobs-dlq --query QueueUrl --output text)" \
  --visibility-timeout 0 --max-number-of-messages 5 --query 'Messages[].Body' --output text
```

- 작업 DLQ: Lambda 로그 `/aws/lambda/dev-cking-image-normalizer`에서 `처리 실패` 줄과 예외
- 결과 DLQ: 앱 로그에서 `image upload result` 경고

## 원인별 대응

- **권한 오류(`AccessDenied`):** 최종 키 접두어가 Lambda 역할의 쓰기 목록(`image_final_prefixes`)에 있는지 본다
- **시간·메모리 초과(`Task timed out`, `Runtime exited`):** 원본 크기와 해상도를 본다. 원본은 5MB·20MP를 넘을 수 없다. 넘지 않는데 초과하면 함수 메모리(1536MB)를 올린다
- **결과 DLQ, 앱 오류:** 앱 로그의 `image upload result handling failed` 예외를 보고 고친다

원인을 고친 뒤 DLQ 메시지를 원래 큐로 되돌린다. 작업 DLQ는 원본이 남아 있을 때만 다시 처리된다. 원본(`raw/`)은 1일 뒤 지워지고, 지워진 뒤에는 Lambda가 원본을 읽지 못해(목록 권한이 없어 404가 아닌 403) 다시 DLQ로 간다. 1일이 지난 메시지는 되돌리지 않고 지운다. 그 업로드는 사용자가 다시 올려야 한다

```bash
# Mac
aws sqs start-message-move-task --source-arn "$(aws sqs get-queue-attributes --queue-url "$(aws sqs get-queue-url --queue-name dev-cking-image-jobs-dlq --query QueueUrl --output text)" --attribute-names QueueArn --query Attributes.QueueArn --output text)"
```

## 해결 확인

DLQ 메시지가 0개이고 경보가 OK로 돌아온다.

## 하면 안 되는 것

- 원본(`raw/`)을 손으로 최종 키에 복사하지 않는다. 정규화(회전, 크기, 형식 검사)를 건너뛴 이미지가 서비스에 나간다
