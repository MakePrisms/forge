# team-vps Terraform

AWS infrastructure for a NixOS-based multi-user forge VPS. Provisions a single
EC2 instance with an optional Elastic IP; the NixOS layer (one directory up)
takes over from there via `deploy-rs`.

The module is generic: same code works for any deployment. The example values
in `terraform.tfvars.example` use `agicash-team-forge` as the first consumer.

## Prerequisites

1. **AWS account** with credentials available to the operator's shell
   (`AWS_PROFILE`, `AWS_ACCESS_KEY_ID`, or `aws sso login`). Credentials are
   never stored in tfvars.
2. **IAM policy** — attach `iam-policy.json` to the principal terraform runs as.
   The policy is region-scoped to `us-east-1`; if you change `aws_region`,
   update the policy's `aws:RequestedRegion` condition to match.
3. **Terraform** >= 1.6.
4. **SSH key pair** for first-boot access. Generate one if you don't have it:
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/agicash-team-forge-key
   ```
   The public half goes into `terraform.tfvars`; the same key is later listed
   in `deploy-config.nix` so `deploy-rs` can reach the box.

## Quickstart

```bash
# 1. Configure inputs
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars   # set name + ssh_public_key

# 2. Initialise (downloads provider, writes .terraform.lock.hcl)
terraform init

# 3. Review
terraform plan

# 4. Apply
terraform apply
```

After apply, terraform prints the outputs. Capture the ones the nix layer
needs:

```bash
terraform output -raw public_ip
terraform output -raw ssh_command
```

## Outputs

| Output         | Use                                                                      |
|----------------|--------------------------------------------------------------------------|
| `instance_id`  | EC2 instance ID for debugging / AWS console links.                       |
| `public_ip`    | EIP (when `allocate_eip = true`) or instance ephemeral IPv4.             |
| `public_dns`   | AWS-assigned DNS name. Useful before real DNS is pointed at the box.     |
| `ssh_command`  | Copy-paste SSH command with a hint key path.                             |
| `name`         | Echo of `var.name`. Makes `terraform output -json \| jq` self-describing.|

## Handoff to nix

The nix layer (one directory up) reads two values from `deploy-config.nix`:
the IP and the SSH public key. Paste them in:

```bash
cd ..
cp deploy-config.nix.example deploy-config.nix
$EDITOR deploy-config.nix    # paste public_ip + ssh_public_key
```

`deploy-config.nix` is gitignored so operator-specific values stay local.

Then deploy with the flake's deploy attribute (see the top-level
`examples/team-vps/README.md` once it exists, or the flake's `deploy` output).

## State files

This module uses local state (no backend block). `terraform.tfstate` lives in
this directory and is gitignored. Sufficient for a single-operator workflow.
For team workflows, add a `backend "s3"` block pointing at a state bucket with
DynamoDB locking; the bootstrap for that bucket is a separate one-time apply.

## Cleanup

```bash
terraform destroy
```

This tears down everything terraform created: EC2 instance, EIP, security
group, key pair. The NixOS layer (deployed via `deploy-rs`) lives on the box's
disk and goes away with the instance.

## TODOs

- **sops-nix wiring** — application/runtime secrets (Discord bot token,
  Anthropic API key, etc.) are out of scope for this PR. They live in the nix
  layer via `sops-nix`: encrypted in the repo, decryption key on each
  operator/box. The `discordBotTokenFile = "/run/secrets/discord-token"`
  shape is what the forge module expects. Wire-up lands with the
  `configuration.nix` PR.
- **Lockdown phase** — the default `ssh_ingress_cidrs = ["0.0.0.0/0"]` is
  Phase-0 bootstrap. Once a VPN-style overlay (Tailscale or similar) is
  installed on the box, narrow `ssh_ingress_cidrs` to the overlay's CIDR
  (or drop SSH from the public security group). Tfvars change, not a code
  change.
