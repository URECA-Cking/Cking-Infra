# 개발 환경의 리소스. 읽기만 하고 변경하지 않는다.

data "aws_vpc" "main" {
  tags = {
    Name = "dev-cking-vpc"
  }
}

data "aws_subnet" "public_2a" {
  vpc_id = data.aws_vpc.main.id

  tags = {
    Name = "dev-cking-subnet-public1-ap-northeast-2a"
  }
}

# AMI를 개발 앱 서버에서 읽어 같은 OS 이미지로 띄운다.
data "aws_instance" "dev_app" {
  filter {
    name   = "tag:Name"
    values = ["dev-cking-app"]
  }
}

data "aws_security_group" "observability" {
  vpc_id = data.aws_vpc.main.id
  name   = "dev-cking-observability-sg"
}

data "aws_s3_bucket" "deploy" {
  bucket = "dev-cking-deploy-551372961758"
}

data "aws_s3_bucket" "observability" {
  bucket = "dev-cking-observability-551372961758-ap-northeast-2-an"
}

data "aws_instance" "observability" {
  filter {
    name   = "tag:Name"
    values = ["dev-cking-observability"]
  }
}

data "aws_security_group" "alb" {
  vpc_id = data.aws_vpc.main.id
  name   = "dev-cking-alb-sg"
}

data "aws_lb" "main" {
  name = "dev-cking-alb"
}

data "aws_lb_listener" "https" {
  load_balancer_arn = data.aws_lb.main.arn
  port              = 443
}

data "aws_route53_zone" "main" {
  name         = "cking.co.kr"
  private_zone = false
}

data "aws_db_subnet_group" "main" {
  name = "dev-cking-db-subnet-group"
}
