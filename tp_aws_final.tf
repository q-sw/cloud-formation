terraform {
  required_version = ">= 0.12.0"
}

provider "aws" {
  region = "eu-west-3"
}

resource "aws_vpc" "vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name  = "cesi_vpc"
    Build = "Build by Terraform"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.vpc.id
}

data "aws_availability_zones" "available_public" {
  state         = "available"
  exclude_names = formatlist("%s%s", "eu-west-3", ["c", "d"])
}

resource "aws_subnet" "public_subnet" {
  count                   = length(data.aws_availability_zones.available_public.names)
  vpc_id                  = aws_vpc.vpc.id
  map_public_ip_on_launch = true
  cidr_block              = cidrsubnet(aws_vpc.vpc.cidr_block, 8, count.index + 1)
  availability_zone       = data.aws_availability_zones.available_public.names[count.index]
  tags = {
    Name  = "subnet-${data.aws_availability_zones.available_public.names[count.index]}-public"
    Build = "Build by Terraform"
  }
}

data "aws_availability_zones" "available_private" {
  state         = "available"
  exclude_names = formatlist("%s%s", "eu-west-3", ["b", "c"])
}

resource "aws_subnet" "private_subnet" {
  count                   = length(data.aws_availability_zones.available_private.names)
  vpc_id                  = aws_vpc.vpc.id
  map_public_ip_on_launch = false
  cidr_block              = "10.0.10.0/24"
  availability_zone       = data.aws_availability_zones.available_private.names[count.index]
  tags = {
    Name  = "subnet-${data.aws_availability_zones.available_private.names[count.index]}-private"
    Build = "Build by Terraform"
  }
}

resource "aws_eip" "nateip" {
  vpc = true
}

resource "aws_nat_gateway" "natgw" {
  allocation_id = aws_eip.nateip.id
  subnet_id     = aws_subnet.public_subnet.0.id

  tags = {
    Name  = "CesiNatgw"
    Build = "Build by Terraform"
  }
}

resource "aws_route" "route_to_nat" {
  route_table_id         = aws_vpc.vpc.default_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id             = aws_nat_gateway.natgw.id
}

resource "aws_route_table" "route_table_igw" {
  vpc_id = aws_vpc.vpc.id
}

resource "aws_route" "route_igw" {
  route_table_id         = aws_route_table.route_table_igw.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.gw.id
}

resource "aws_route_table_association" "a" {
  count          = length(aws_subnet.public_subnet)
  subnet_id      = element(aws_subnet.public_subnet.*.id, count.index)
  route_table_id = aws_route_table.route_table_igw.id
}

resource "aws_key_pair" "keypair" {
  key_name   = "cesi-tp-keypair"
  public_key = file("aws_cesi.pub")
}

resource "aws_security_group" "sg_bastion_ssh" {
  name   = "SG_BASTION_SSH"
  vpc_id = aws_vpc.vpc.id
  tags = {
    Name  = "SG_BASTION_SSH"
    Build = "Build by tf-module-aws-securitygroup"
  }
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "all"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_instance" "bastion" {
  count                  = 1
  ami                    = "ami-0ea4a063871686f37"
  instance_type          = "t2.micro"
  key_name               = aws_key_pair.keypair.key_name
  vpc_security_group_ids = [aws_security_group.sg_bastion_ssh.id]
  subnet_id              = aws_subnet.public_subnet.0.id
  root_block_device {
    volume_type = "gp2"
    volume_size = "10"
  }
  tags = {
    Name  = "BASTION"
    Build = "Build by Terraform"
  }
}

resource "aws_security_group" "sg_private_app" {
  name   = "SG_PRIVATE_APP"
  vpc_id = aws_vpc.vpc.id
  tags = {
    Name  = "SG_PRIVATE_APP"
    Build = "Build by tf-module-aws-securitygroup"
  }
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "all"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "sg_private_ssh" {
  name   = "SG_PRIVATE_SSH"
  vpc_id = aws_vpc.vpc.id
  tags = {
    Name  = "SG_PRIVATE_SSH"
    Build = "Build by tf-module-aws-securitygroup"
  }
}

resource "aws_security_group_rule" "ssh_private_access" {
  type                      = "ingress"
  from_port                 = 22
  to_port                   = 22
  protocol                  = "tcp"
  source_security_group_id  = aws_security_group.sg_bastion_ssh.id
  security_group_id         = aws_security_group.sg_private_ssh.id
}

resource "aws_instance" "app" {
  count                  = 1
  ami                    = "ami-0ea4a063871686f37"
  instance_type          = "t2.micro"
  key_name               = aws_key_pair.keypair.key_name
  vpc_security_group_ids = [aws_security_group.sg_private_app.id, aws_security_group.sg_private_ssh.id ]
  subnet_id              = aws_subnet.private_subnet.0.id
  root_block_device {
    volume_type = "gp2"
    volume_size = "10"
  }
  tags = {
    Name  = "APP"
    Build = "Build by Terraform"
  }
}

resource "aws_lb" "nlb" {
  name               = "cesilb"
  internal           = "false"
  load_balancer_type = "network"
  subnets            = aws_subnet.public_subnet.*.id

  enable_deletion_protection = false

  tags = {
        Name         = "cesilb"
        Build        = "Build by tf-module-aws-lb"
    }
}
resource "aws_lb_target_group" "targetgroup" {
  name = "cesiPrivateApp"
  port = "80"
  protocol = "TCP"
  vpc_id = aws_vpc.vpc.id
}

resource "aws_lb_target_group_attachment" "tg-attachment" {
    count = length(aws_instance.app)
    target_group_arn = aws_lb_target_group.targetgroup.arn
    target_id = element(aws_instance.app.*.id, count.index)
}
resource "aws_lb_listener" "lb-listener" {
    load_balancer_arn = aws_lb.nlb.arn
    port = 80
    protocol = "TCP"
    default_action{
        type = "forward"
        target_group_arn = aws_lb_target_group.targetgroup.arn
    }
}