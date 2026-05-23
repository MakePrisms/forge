output "instance_id" {
  description = "ID of the EC2 instance"
  value       = aws_instance.this.id
}

output "public_ip" {
  description = "Public IP of the instance. The EIP when allocate_eip = true, the instance's ephemeral IPv4 otherwise."
  value       = var.allocate_eip ? aws_eip.this[0].public_ip : aws_instance.this.public_ip
}

output "public_dns" {
  description = "AWS-assigned public DNS name of the instance"
  value       = aws_instance.this.public_dns
}

output "ssh_command" {
  description = "SSH command to connect to the instance. Adjust the key path to wherever you stored the private key matching ssh_public_key."
  value       = "ssh -i ~/.ssh/${var.name}-key root@${var.allocate_eip ? aws_eip.this[0].public_ip : aws_instance.this.public_ip}"
}

output "name" {
  description = "Echo of var.name — makes `terraform output -json | jq` self-describing for downstream consumers (e.g. deploy-config.nix generation)."
  value       = var.name
}
