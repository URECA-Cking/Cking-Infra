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

# 역할은 envs/loadtest-base에서 먼저 만든다. 없으면 plan이 여기서 멈춘다.
data "aws_iam_instance_profile" "app" {
  name = "loadtest-cking-app-role"
}

data "aws_iam_instance_profile" "k6" {
  name = "loadtest-cking-k6-role"
}
