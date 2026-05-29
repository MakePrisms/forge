# team-vps Terraform

AWS infrastructure for a NixOS-based multi-user forge VPS. Provisions a single
EC2 instance with an optional Elastic IP; the NixOS layer (one directory up)
takes over from there via `deploy-rs`.

## Prerequisites

1. **AWS credentials** in the shell (`AWS_PROFILE`, `AWS_ACCESS_KEY_ID`, or
   `aws sso login`). Never stored in tfvars.
2. **IAM policy** — attach `../../../iam-policy.json` to the principal
   terraform runs as. Repo-wide, not specific to this deployment. Region-scoped
   to `us-east-1`; if you change `aws_region`, update the policy's
   `aws:RequestedRegion` condition to match.
3. **`nix develop`** at the repo root gets you `tofu`, `aws`, `sops`, `age`,
   `jq`, and `deploy` on PATH at flake-pinned versions.
4. **Your SSH public key in `../authorized-keys`** — that file is the single
   source of truth for SSH on this box (both terraform's `aws_key_pair` and
   nix's `users.users.<u>.openssh.authorizedKeys.keys` read it). Append your
   pubkey and commit before deploying. Generate one if you don't have one:
   ```bash
   ssh-keygen -t ed25519 -C "your-handle@laptop"
   ```

## Quickstart

From the repo root:

```bash
nix develop
cd deployments/agicash-team-forge/terraform
tofu init && tofu apply
cd ../../..
nix run .#deploy
```

That's it. No `terraform.tfvars` file is required for the default deployment;
`tofu apply` resolves `name` and `ssh_public_key` from sensible defaults
(`agicash-team-forge`, and the first non-comment line of
`../authorized-keys`). `nix run .#deploy` reads the box's public IP from
`tofu output -raw public_ip` and hands it to `deploy-rs` via `--hostname`.

## Outputs

| Output | Use |
|---|---|
| `instance_id` | EC2 instance ID for debugging / console links. |
| `public_ip` | EIP (when `allocate_eip = true`) or instance ephemeral IPv4. Consumed by `nix run .#deploy`. |
| `public_dns` | AWS-assigned DNS name. Useful before real DNS is pointed at the box. |
| `ssh_command` | Copy-paste SSH command with a hint key path. |
| `name` | Echo of `var.name`. Makes `tofu output -json \| jq` self-describing. |

## Overriding defaults

`terraform.tfvars` is optional. Copy `terraform.tfvars.example` only if you
need to override one of:

- `name` (default `agicash-team-forge`) — set when bringing up a sibling deployment.
- `ssh_public_key` — set only if you need to bootstrap with a key that isn't
  the first entry in `../authorized-keys`. Most of the time, **adding your
  pubkey to `authorized-keys`** is the right move instead.
- `aws_region`, `instance_type`, `root_volume_size`, `ssh_ingress_cidrs`,
  `allow_http`, `extra_ingress_ports`, `allocate_eip`, `nixos_ami_channel`,
  `tags` — defaults documented in `variables.tf`.

Env-var overrides (`TF_VAR_<name>=…`) work the same.

## State files

This module uses local state. `terraform.tfstate` lives here and is gitignored.
Sufficient for a single-operator workflow. For team workflows, add a
`backend "s3"` block pointing at a state bucket with DynamoDB locking;
the bootstrap for that bucket is a separate one-time apply.

## Cleanup

```bash
tofu destroy
```

Tears down everything terraform created: EC2, EIP, security group, key pair.
The NixOS layer (deployed via `deploy-rs`) lives on the box's disk and goes
away with the instance.

## TODOs

- **sops-nix wiring** — application/runtime secrets (Discord bot token,
  Anthropic API key, etc.) live in the nix layer via `sops-nix`. See
  `docs/secrets-bootstrap.md`.
- **Lockdown phase** — the default `ssh_ingress_cidrs = ["0.0.0.0/0"]` is
  Phase-0 bootstrap. Once a VPN-style overlay (Tailscale or similar) is
  installed on the box, narrow `ssh_ingress_cidrs` to the overlay's CIDR
  (or drop SSH from the public security group).
