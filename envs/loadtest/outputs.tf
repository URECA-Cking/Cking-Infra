output "app_instance_id" {
  value = aws_instance.app.id
}

output "app_private_ip" {
  value = aws_instance.app.private_ip
}

output "app_security_group_id" {
  value = aws_security_group.app.id
}

output "api_url" {
  value = "https://${local.api_host}"
}

output "db_address" {
  value = aws_db_instance.main.address
}

output "k6_instance_id" {
  value = aws_instance.k6.id
}
