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

  # Authorized SSH pubkeys: read from ../authorized-keys, the same file nix
  # ingests for users.users.<u>.openssh.authorizedKeys.keys at activation
  # time. One source of truth; bootstrap key and ongoing access stay aligned
  # by construction.
  authorized_keys = [
    for line in split("\n", file("${path.module}/../authorized-keys")) :
    trimspace(line)
    if length(trimspace(line)) > 0 && !startswith(trimspace(line), "#")
  ]

  # Effective bootstrap key: explicit var wins; otherwise first entry in
  # authorized-keys. The aws_key_pair resource is first-boot-only — every
  # entry in authorized-keys is authorized once nix activation lands.
  ssh_public_key = (
    var.ssh_public_key != ""
    ? var.ssh_public_key
    : try(local.authorized_keys[0], "")
  )
}

# Key pair for first-boot SSH access
resource "aws_key_pair" "this" {
  key_name   = "${var.name}-key"
  public_key = local.ssh_public_key

  lifecycle {
    precondition {
      condition = can(regex("^(ssh-(rsa|ed25519|ecdsa)|ecdsa-sha2-)", local.ssh_public_key))
      error_message = <<-EOT
        No valid SSH public key resolved for the first-boot aws_key_pair.

        The bootstrap key comes from `../authorized-keys` (first non-comment,
        non-blank line) by default. Provide a key via either:
          - Appending an OpenSSH pubkey to ../authorized-keys, or
          - Setting TF_VAR_ssh_public_key="$(cat path/to/key.pub)", or
          - Adding ssh_public_key = "ssh-..." to terraform.tfvars.

        Got: "${substr(local.ssh_public_key, 0, 60)}"
      EOT
    }
  }

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
