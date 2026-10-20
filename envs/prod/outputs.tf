output "network" {
  value = {
    vpc_id         = aws_vpc.main.id
    subnet_ids     = { for k, s in aws_subnet.this : k => s.id }
    nat_public_ips = [for e in aws_eip.nat : e.public_ip]
  }
}
