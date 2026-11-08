# zip 함수를 처음 만들 때 쓰는 임시 코드. 특정 빌드 산출물에 묶이지 않도록 Terraform이 직접 묶는다.
# 실제 코드는 배포 워크플로(deploy-image-normalizer)가 넣고, 함수는 코드를 비교하지 않는다.
# S3 알림을 만들 때 큐로 오는 s3:TestEvent만 성공으로 넘긴다. 실패로 두면 재시도 끝에 작업 DLQ로 가 경보가 울린다.
locals {
  lambda_bootstrap_code = <<-EOT
    import json


    def handler(event, context):
        records = event.get("Records") or []
        if records and all(json.loads(r.get("body") or "{}").get("Event") == "s3:TestEvent" for r in records):
            return {"batchItemFailures": []}
        raise RuntimeError("배포 전 임시 코드")
  EOT
}

data "archive_file" "lambda_bootstrap" {
  type        = "zip"
  output_path = "${path.module}/.build/lambda-bootstrap.zip"

  dynamic "source" {
    for_each = toset(["handler.py"])
    content {
      filename = source.value
      content  = local.lambda_bootstrap_code
    }
  }
}
