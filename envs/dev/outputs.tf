output "foundation" {
  description = "개발 기반 리소스 ID"
  value = {
    vpc_id                   = aws_vpc.main.id
    alb_arn                  = aws_lb.main.arn
    https_listener_arn       = aws_lb_listener.https.arn
    app_instance_id          = aws_instance.app.id
    app_deploy_role_arn      = aws_iam_role.app_deploy.arn
    db_address               = aws_db_instance.main.address
    frontend_bucket          = aws_s3_bucket.frontend.bucket
    frontend_distribution_id = aws_cloudfront_distribution.frontend.id
  }
}

output "admin_frontend" {
  description = "관리자 앱 버킷·배포 ID·배포 역할"
  value = {
    bucket          = aws_s3_bucket.admin_frontend.bucket
    distribution_id = aws_cloudfront_distribution.admin_frontend.id
    deploy_role_arn = aws_iam_role.frontend_deploy.arn
  }
}

output "observability" {
  description = "관측 서버 정보"
  value = {
    instance_id = aws_instance.observability.id
    private_ip  = aws_instance.observability.private_ip
    bucket      = aws_s3_bucket.observability.bucket
  }
}

output "recommendation" {
  description = "추천 배치 저장소 CI에 넣을 값"
  value = {
    deploy_role_arn   = aws_iam_role.recommendation_deploy.arn
    release_prefix    = "s3://dev-cking-deploy-${local.account_id}/recommendation/releases/"
    release_parameter = "/cking/dev-recommendation/RELEASE"
    server_group      = aws_autoscaling_group.recommendation.name
    state_volume_id   = aws_ebs_volume.recommendation_state.id
  }
}

output "comment_filter" {
  description = "필터 저장소 CI와 BE 개발 설정에 넣을 값"
  value = {
    repository_url  = aws_ecr_repository.comment_filter.repository_url
    deploy_role_arn = aws_iam_role.comment_filter_deploy.arn
    function_url    = aws_lambda_function_url.comment_filter.function_url
  }
}
