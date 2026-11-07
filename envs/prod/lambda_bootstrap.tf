# zip 함수를 처음 만들 때 쓰는 임시 코드. 특정 빌드 산출물에 묶이지 않도록 Terraform이 직접 묶는다.
# 실제 코드는 배포 워크플로(deploy-image-normalizer)가 넣고, 함수는 코드를 비교하지 않는다.
data "archive_file" "lambda_bootstrap" {
  type        = "zip"
  output_path = "${path.module}/.build/lambda-bootstrap.zip"

  dynamic "source" {
    for_each = toset(["handler.py"])
    content {
      filename = source.value
      content  = "def handler(event, context):\n    raise RuntimeError(\"배포 전 임시 코드\")\n"
    }
  }
}
