# Terraform Plan: `deployments/agicash-team-forge/terraform/`

Status: design proposal — no code yet.

## Goals and constraints

- Provision the AWS infrastructure for a NixOS-based multi-user forge VPS.
- Stay generic: the terraform layer takes a deployment as input (name, region, sizes, keys) so the same module works for any consumer. The first consumer (`name = "agicash-team-forge"`) is just the first.
- Stay nix-native: terraform builds the box; nix pushes the system. The handoff is one terraform output (the IP) plus one SSH key.
- Mirror the proven shape of `agicash-mints/terraform/` so anyone familiar with that repo lands here instantly.
- Start minimal. No DNS automation, no IAM module abstraction, no multi-AZ, no autoscaling — those land later if needed.

## 1. Module structure

Layout under `deployments/agicash-team-forge/`:

```
deployments/agicash-team-forge/
  flake.nix              # already exists — will gain deploy outputs
  configuration.nix      # already exists — NixOS module composition
  deploy-config.nix.example   # NEW — hostname + SSH key (gitignored when copied)
  terraform/
    main.tf              # AMI lookup, key pair, security group, EIP, EC2 instance
    variables.tf         # All inputs (no consumer-specific defaults)
    outputs.tf           # public_ip, public_dns, ssh_command, instance_id
    versions.tf          # required_version + required_providers (pinned)
    iam-policy.json      # least-privilege policy for the terraform principal
    terraform.tfvars.example  # template — copy to terraform.tfvars
    README.md            # quick start + cleanup
```

Why split `versions.tf` out of `main.tf` (vs. agicash-mints which puts it in `main.tf`): conventional terraform layout, makes the pin block easy to find, keeps `main.tf` focused on resources.

Why a single flat directory and not a child module under `deployments/agicash-team-forge/terraform/modules/vps/`: a child module makes sense when there are multiple callers. Today there's one. Keep it flat now; promote to a child module if/when a real second caller appears.

Per-resource breakdown (`main.tf`):

| Resource | Purpose | Conditional? |
|----------|---------|--------------|
| `data.aws_ami.nixos` | Official NixOS AMI lookup (owner `427812963091`) | — |
| `data.aws_vpc.default` | Default VPC for the region | — |
| `aws_key_pair.this` | SSH key for first-boot access | — |
| `aws_security_group.this` | Ingress 22/80/443, egress all | — |
| `aws_eip.this` | Persistent IP for nix-side hostname | `var.allocate_eip` |
| `aws_eip_association.this` | Pin EIP to instance | `var.allocate_eip` |
| `aws_instance.this` | EC2 with NixOS AMI, gp3 encrypted root | — |

Names use `this` instead of `agicash_*` so the resources don't look project-specific in the state file. Project naming is carried by `var.name` and tags.

## 2. Variables and inputs

All variables live in `variables.tf`. No consumer-specific defaults. The caller supplies everything that's deployment-specific.

| Variable | Type | Default | Required | Purpose |
|---|---|---|---|---|
| `name` | string | — | yes | Used as `Name`/`Project` tag and resource prefix. Canonical first-consumer value: `agicash-team-forge`. |
| `aws_region` | string | `"us-east-1"` | no | AWS region. Single region per apply. |
| `instance_type` | string | `"t3.medium"` | no | EC2 instance class. See cost envelope + open questions — may need to grow if on-box Rust builds get painful. |
| `root_volume_size` | number | `100` | no | gp3 root size in GB. Sized for Nix store + multi-user homes + Rust `target/` build outputs. |
| `ssh_public_key` | string | — | yes | A *single* SSH public key authorized at first boot (the `aws_key_pair`). The full team key list is managed in the NixOS config (`authorized_keys` per user), not here — this is bootstrap only. |
| `ssh_ingress_cidrs` | list(string) | `["0.0.0.0/0"]` | no | Phase-0 bootstrap allows open SSH so the operator can do the first deploy. See "Security posture" below. |
| `allow_http` | bool | `true` | no | Whether to open 80 and 443. False for headless internal-only VPSes. |
| `extra_ingress_ports` | list(number) | `[]` | no | Additional TCP ports to open from `ssh_ingress_cidrs` source. Simple list of ports; promote to per-port CIDR objects if a real use case appears. |
| `allocate_eip` | bool | `true` | no | Allocate + associate an Elastic IP. When `false`, `public_ip` output is the instance's ephemeral IPv4 (caller's responsibility to handle restart-changes-IP). |
| `nixos_ami_channel` | string | `"24.11"` | no | NixOS channel filter passed to the AMI data source (`nixos/${channel}*`). |
| `tags` | map(string) | `{}` | no | Free-form extra tags merged onto every resource. `ManagedBy = "terraform"` and `Project = var.name` are added unconditionally. |

Deliberately not in v1: VPC creation (use default VPC), subnet selection (default), IAM instance profile (no AWS calls from the box yet), Route53 (DNS managed externally), EBS data volumes (root only), multiple instances (one per apply).

## 3. Outputs

`outputs.tf` emits the contract that the nix layer reads:

| Output | Purpose |
|---|---|
| `instance_id` | EC2 instance ID for debugging / AWS console links. |
| `public_ip` | EIP when `allocate_eip = true`, instance ephemeral IPv4 otherwise. Single source of truth for "where is this box". Consumed by `deploy-config.nix`. |
| `public_dns` | AWS-assigned DNS name. Useful when teams haven't pointed real DNS yet. |
| `ssh_command` | Convenience: copy-paste SSH command with the right key path hint. |
| `name` | Echo of `var.name` — so `terraform output -json \| jq` gives nix everything it needs in one shot. |

All outputs non-sensitive. State file holds the EIP allocation but no secrets (no IAM credentials, no passwords, no token material).

## 4. Nix integration

**Choice: `deploy-rs`.**

**Builds happen on the target machine** (`remoteBuild = true`). The box has the disk + Nix store; the operator's laptop doesn't need either.

Operators deploy from their laptop. The deploy command also works from CI if someone wants to wire that up later, but the design center is local.

Justification:

- agicash-mints already runs deploy-rs in production; the operator-level workflow is known to work end-to-end on AWS NixOS AMIs.
- Magic rollback (auto-revert if SSH breaks post-activation) is a real safety win for a multi-user box where a bad config locks everyone out.
- It is flake-native: a `deploy` attribute on the flake, no extra config file format to learn.

Alternatives considered:

- **nixos-anywhere**: excellent for first deploy onto bare metal / generic Linux. We don't need it because the NixOS AMI is already booted NixOS.
- **colmena**: similar feature set to deploy-rs, marginally more ergonomic for multi-host fleets. We have one host per deployment. No win.
- **morph**: heavier, less actively maintained.
- **Plain `nixos-rebuild --target-host`**: simplest, no extra dep. Loses magic rollback and the explicit `deploy.<name>` flake attribute we want as the standard ritual.

Verdict: deploy-rs for v1. If we hit deploy-rs friction (build perf, flake eval cost) we can fall back to `nixos-rebuild --target-host` without changing the terraform contract — the interface between terraform and nix is just "give me an IP and an SSH key path."

### Flow

```
1. cp terraform.tfvars.example terraform.tfvars && edit
2. terraform init && terraform apply
3. terraform output -raw public_ip > /tmp/ip   # or copy by hand
4. cp deploy-config.nix.example deploy-config.nix && paste IP + key
5. nix run .#deploy.agicash-team-forge
6. (optional) point DNS at the EIP
```

`deploy-config.nix` is the seam. It is gitignored (per agicash-mints precedent) so each operator's IP/keys stay local. Shape: `{ hostname = "..."; sshPublicKeys = [ ... ]; }`.

## 5. Reproducibility

**Pinned:**
- Terraform required version: `>= 1.6`.
- AWS provider: `~> 5.0`, lockfile committed (`.terraform.lock.hcl` in git).
- NixOS AMI: looked up via data source filtered on channel name (`nixos/24.11*`). **Not** pinned to a specific AMI ID — the official NixOS AMI is rebuilt frequently with security patches; bias toward newest patch of pinned channel. If a future deploy needs *exact* reproducibility, add an `ami_id` escape hatch then.
- NixOS channel: pinned via `nixos_ami_channel` variable, default `"24.11"`. Bumping is a deliberate input change.

### Secrets

Three layers, separated by what owns them:

1. **Terraform-side**: only `ssh_public_key` is sensitive-ish. Public keys aren't secret, but `terraform.tfvars` stays gitignored anyway so operator-specific values don't land in the repo.
2. **Application/runtime secrets** (Discord bot tokens, Anthropic API key, etc.): live in the nix layer via `sops-nix` — encrypted in the repo, decryption key on each operator/box. The forge module is already designed for this pattern (`discordBotTokenFile = "/run/secrets/discord-token"` shape). Wire-up of sops-nix lands in the configuration.nix PR, not this terraform PR.
3. **AWS credentials**: provided to terraform via the operator's environment (`AWS_PROFILE`, `AWS_ACCESS_KEY_ID`, or `aws sso`). Never in tfvars. Documented in README.

### State files

- **v1 (this PR):** no backend block. State lives in `terraform/terraform.tfstate`, gitignored. Sufficient for a single-operator local workflow.
- **v2 (when needed):** `backend "s3"` pointing at a bucket like `s3://makeprisms-tf-state/<name>.tfstate` with DynamoDB locking. The bootstrap for that bucket is a separate one-time terraform apply (cycle problem otherwise).

README should note this trade-off so the next operator isn't surprised.

## 6. Security posture

**Two phases. Only Phase 0 is in scope for this plan.**

- **Phase 0 — Bootstrap (in scope):** SSH ingress open to `ssh_ingress_cidrs` default `["0.0.0.0/0"]`. Operator does first `deploy-rs` activation. Wheels-on state.
- **Phase 1 — Lockdown (TBD, not in this plan):** Once a VPN-style overlay (Tailscale or similar) is installed on the box via the NixOS module, narrow `ssh_ingress_cidrs` to the overlay's CIDR, or remove SSH from the public security group entirely. The overlay mechanism is a separate design.

What this means for the terraform code:
- `ssh_ingress_cidrs` is a parameterized variable from day one so Phase 1 is a tfvars change, not a code change.
- The security group resource doesn't bake in any specific lockdown — operators flip the variable when they're ready.

## 7. Cost envelope

Per box at the default sizes:

- **Compute** (`t3.medium`, on 24/7): ~$30/mo
- **Storage** (100GB gp3 root): ~$8/mo
- **EIP** (attached to a running instance): $0; ~$3.60/mo if left allocated but unattached
- **Egress** (NixOS pulls, deploy bandwidth): negligible at this scale, count $1-2/mo headroom
- **S3 state backend** (when added): cents

**Approximately $40/mo per box.**

Caveat: `t3.medium` (2 vCPU / 4GB) is undersized for heavy on-box Rust builds. Compiling an agicash-sized Rust workspace will be slow. The plan keeps `t3.medium` as the default for cost discipline; instance class can be revised when build throughput becomes painful. See open questions.

## 8. Departures from agicash-mints

Explicit deltas from the agicash-mints/terraform pattern, so future readers don't assume parity:

- **No `domain_name` variable** — application-layer concern, not infrastructure.
- **Generic resource names** (`aws_instance.this`, not `aws_instance.agicash_mints`) — keeps the state file unprefixed for future module extraction.
- **No `project_name` separate from `name`** — collapsed to one.
- **Singular `ssh_public_key`** (not `list(string)`) — full team keys live in the nix layer.
- **Larger root volume** (100GB default vs. 20GB) — for Nix store + multi-user homes + Rust `target/`.
- **No IAM instance profile by default** — forge boxes don't need to call the AWS API. Add later if/when something inside the box needs S3 access etc.
- **`terraform.tfvars` gitignored even though `ssh_public_key` isn't secret** — operator-specific values shouldn't live in the repo.
- **deploy-rs build-on-machine policy reaffirmed** — same tool as agicash-mints, but with `remoteBuild = true` promoted to a first-class decision rather than a parenthetical.

## 9. Architectural hooks for future re-use

This plan does *not* deliver an ephemeral / throwaway-box example. But it shapes the terraform so a future sibling example or extracted child module is mechanical, not a fork:

- **Generic resource names** (`aws_instance.this`) — already noted in section 8.
- **All ingress is configurable** (`ssh_ingress_cidrs`, `allow_http`, `extra_ingress_ports`) so a locked-down or wide-open variant is a tfvars change, not a code fork.
- **No hardcoded `Project` tag** — derived from `var.name`.
- **EIP is optional** (`allocate_eip`) so a no-EIP throwaway is one boolean.

If/when a real second caller appears, extract `terraform/` into `modules/terraform/aws-nixos-vps/` and let the two callers be thin. Don't do it preemptively.

## 10. Open questions

Resolved in this revision (kept here as a closed log so the answer travels with the doc):

- **Q1 (single bootstrap key vs. list?)** → singular. Section 2.
- **Q2 (canonical `name` value?)** → `agicash-team-forge`. Deployment dir is `deployments/agicash-team-forge/`.
- **Q4 (EIP always-on?)** → `allocate_eip` variable, default `true`. Section 2.
- **Q5 (`extra_ingress_ports` model + security posture)** → `list(number)` for ports; security posture written up in section 6 as a two-phase model.
- **Q6 (root volume size)** → 100GB default.

Still open before implementation:

1. **Region default — `us-east-1` or no default?** agicash-mints defaults to `us-east-1`; the IAM policy is region-scoped to `us-east-1`. Current recommendation: keep `us-east-1` default for ergonomic parity, document the IAM-policy-must-match constraint in README.
2. **Provider version pin precision** — `~> 5.0` (matches agicash-mints), `~> 5.70` (lock minor), or `>= 5.0` (looser)? Current recommendation: `~> 5.0`, lockfile commit handles the tight pin in practice.
3. **deploy-rs vs plain `nixos-rebuild --target-host` for the absolute first deploy?** Magic rollback only protects activation, not initial install. Current recommendation: deploy-rs from day one for consistency.
4. **sops-nix wiring location** — does secrets bootstrap (admin key, age key generation) belong in `deployments/agicash-team-forge/README.md` or in a forge-level doc? Flagging so it doesn't get lost.
5. **Instance class for Rust builds** — `t3.medium` is the start (per section 7 cost discipline). Revisit when on-box `cargo build` of an agicash-sized workspace gets painful — likely move to `t3.large` (~$60/mo) or `m6i.large` for memory headroom.
