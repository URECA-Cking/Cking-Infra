output "app_instance_profile" {
  value = aws_iam_instance_profile.app.name
}

output "recommendation_instance_profile" {
  value = aws_iam_instance_profile.recommendation.name
}
