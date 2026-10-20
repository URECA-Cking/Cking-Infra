output "app_instance_profile" {
  value = aws_iam_instance_profile.app.name
}

output "k6_instance_profile" {
  value = aws_iam_instance_profile.k6.name
}
