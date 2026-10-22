output "app_instance_profile" {
  value = aws_iam_instance_profile.app.name
}

output "recommendation_instance_profile" {
  value = aws_iam_instance_profile.recommendation.name
}

output "monitor_instance_profile" {
  value = aws_iam_instance_profile.monitor.name
}

output "k6_instance_profile" {
  value = aws_iam_instance_profile.k6.name
}

output "rds_monitoring_role_arn" {
  value = aws_iam_role.rds_monitoring.arn
}
