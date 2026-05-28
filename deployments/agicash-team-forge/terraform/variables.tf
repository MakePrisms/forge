variable "name" {
  description = "Deployment name. Used as the Name and Project tag, and as the prefix for resource names (key pair, security group, etc.)."
  type        = string
}

variable "aws_region" {
  description = "AWS region for all resources. Single region per apply. Must match the region scoped in iam-policy.json."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type. Default is undersized for heavy on-box Rust builds — bump to t3.large or m6i.large when compile throughput becomes painful."
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size" {
  description = "Size of the root EBS volume in GB. Sized for the Nix store + multi-user homes + Rust target/ build outputs."
  type        = number
  default     = 100
}

variable "ssh_public_key" {
  description = "A single SSH public key authorized at first boot via aws_key_pair. The full team key list is managed in the NixOS config (authorized_keys per user), not here — this is bootstrap only."
  type        = string
}

variable "ssh_ingress_cidrs" {
  description = "CIDR blocks allowed to SSH (port 22) and reach extra_ingress_ports. Phase-0 bootstrap default allows the whole internet so the operator can do the first deploy; narrow this once a VPN-style overlay is wired in via the NixOS module."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "allow_http" {
  description = "Whether to open ports 80 and 443 to the world. Set to false for headless internal-only VPSes."
  type        = bool
  default     = true
}

variable "extra_ingress_ports" {
  description = "Additional TCP ports to open from ssh_ingress_cidrs. Simple list of ports; promote to per-port CIDR objects if a real use case appears."
  type        = list(number)
  default     = []
}

variable "allocate_eip" {
  description = "Allocate and associate an Elastic IP. When false, the public_ip output is the instance's ephemeral IPv4 and changes across stop/start."
  type        = bool
  default     = true
}

variable "nixos_ami_channel" {
  description = "NixOS channel filter passed to the AMI data source (nixos/$${channel}*). Bumping is a deliberate input change."
  type        = string
  default     = "25.11"
}

variable "tags" {
  description = "Free-form extra tags merged onto every resource. ManagedBy = \"terraform\", Project = var.name, and Name = var.name are added unconditionally."
  type        = map(string)
  default     = {}
}
