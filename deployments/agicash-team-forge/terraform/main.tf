# Data sources

data "aws_availability_zones" "available" {
  state = "available"
}

# Latest official NixOS AMI for the channel set by var.nixos_ami_channel
# (default "24.11" — NixOS 24.11 stable, not unstable). Not pinned to a
# specific AMI ID; tracks whatever the channel publishes most recently.
data "aws_ami" "nixos" {
  most_recent = true
  owners      = ["427812963091"] # Official NixOS

  filter {
    name   = "name"
    values = ["nixos/${var.nixos_ami_channel}*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# Get the default VPC
data "aws_vpc" "default" {
  default = true
}

# Subnets in the default VPC. We pick the first one for aws_instance.this.
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

locals {
  tags = merge(
    {
      Name      = var.name
      Project   = var.name
      ManagedBy = "terraform"
    },
    var.tags,
  )
}

# Key pair for first-boot SSH access
resource "aws_key_pair" "this" {
  key_name   = "${var.name}-key"
  public_key = var.ssh_public_key

  tags = local.tags
}

# Security group
resource "aws_security_group" "this" {
  name_prefix = "${var.name}-sg"
  description = "Security group for ${var.name} deployment"
  vpc_id      = data.aws_vpc.default.id

  # SSH access
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_ingress_cidrs
  }

  # HTTP
  dynamic "ingress" {
    for_each = var.allow_http ? [80] : []
    content {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  # HTTPS
  dynamic "ingress" {
    for_each = var.allow_http ? [443] : []
    content {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  # Extra ingress ports
  dynamic "ingress" {
    for_each = var.extra_ingress_ports
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = var.ssh_ingress_cidrs
    }
  }

  # All outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

# Elastic IP (optional)
resource "aws_eip" "this" {
  count  = var.allocate_eip ? 1 : 0
  domain = "vpc"

  tags = local.tags
}

# EC2 Instance
resource "aws_instance" "this" {
  ami                    = data.aws_ami.nixos.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.this.key_name
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.this.id]

  # EBS root volume
  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true

    tags = local.tags
  }

  tags = local.tags
}

# Associate Elastic IP with the instance
resource "aws_eip_association" "this" {
  count         = var.allocate_eip ? 1 : 0
  instance_id   = aws_instance.this.id
  allocation_id = aws_eip.this[0].id
}
