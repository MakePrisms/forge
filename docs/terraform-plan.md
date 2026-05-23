# Terraform Plan: `examples/team-vps/terraform/`

Status: design proposal — no code yet.

## Goals and constraints

- Provision the AWS infrastructure for a NixOS-based multi-user forge VPS.
- Stay generic: the terraform layer takes a deployment as input (name, region, sizes, keys) so the same module works for agicash today and ephemeral test instances tomorrow.
- Stay nix-native: terraform builds the box; nix pushes the system. The handoff is one terraform output (the IP) plus one SSH key path.
- Mirror the proven shape of `agicash-mints/terraform/` so anyone familiar with that repo lands here instantly.
- Start minimal. No DNS automation, no IAM module abstraction, no multi-AZ, no autoscaling — those land later if needed.

## 1. Module structure

Layout under `examples/team-vps/`:

```
examples/team-vps/
  flake.nix              # already exists — will gain deploy outputs
  configuration.nix      # already exists — NixOS module composition
  deploy-config.nix.example   # NEW — hostname + SSH keys (gitignored when copied)
  terraform/
    main.tf              # AMI lookup, key pair, security group, EIP, EC2 instance
    variables.tf         # All inputs (no agicash-specific defaults)
    outputs.tf           # public_ip, public_dns, ssh_command, instance_id
    versions.tf          # required_version + required_providers (pinned)
    iam-policy.json      # least-privilege policy for the terraform principal
    terraform.tfvars.example  # template — copy to terraform.tfvars
    README.md            # quick start + cleanup
```

Why split `versions.tf` out of `main.tf` (vs. agicash-mints which puts it in `main.tf`): a separate `versions.tf` is the conventional terraform layout, makes the pin block easy to find, and keeps `main.tf` focused on resources. The agicash-mints inline approach also works — minor stylistic preference, not load-bearing.

Why a single flat directory and not a child module under `examples/team-vps/terraform/modules/vps/`: a child module makes sense when there are multiple callers in the same repo. Today there's one caller (this example) and at most a second one later (an ephemeral example). Keep it flat now; promote to a child module when we have the second caller and can see the real shape of the duplication.

Per-resource breakdown (`main.tf`):

| Resource | Purpose | Comes from agicash-mints? |
|----------|---------|---------------------------|
| `data.aws_ami.nixos` | Official NixOS AMI lookup (owner `427812963091`) | yes |
| `data.aws_vpc.default` | Default VPC for the region | yes |
| `aws_key_pair.this` | SSH key for first-boot access | yes |
| `aws_security_group.this` | Ingress 22/80/443, egress all | yes |
| `aws_eip.this` | Persistent IP for nix-side hostname | yes |
| `aws_instance.this` | EC2 with NixOS AMI, gp3 encrypted root | yes |
| `aws_eip_association.this` | Pin EIP to instance | yes |

Names use `this` instead of `agicash_*` so the resources don't look project-specific in the state. Project naming is carried by the `name` variable and tags.

## 2. Variables and inputs

All variables live in `variables.tf`. No agicash-specific defaults. The caller supplies everything that's deployment-specific.

| Variable | Type | Default | Required | Purpose |
|---|---|---|---|---|
| `name` | string | — | yes | Used as `Name`/`Project` tag and resource prefix (e.g. `agicash-team-vps`, `forge-ephemeral-1`). |
| `aws_region` | string | `"us-east-1"` | no | AWS region. Single region per apply. |
| `instance_type` | string | `"t3.medium"` | no | EC2 instance class. |
| `root_volume_size` | number | `30` | no | gp3 root size in GB. Bumped vs. agicash-mints' 20 because forge boxes host Nix store for multiple users. |
| `ssh_public_keys` | list(string) | — | yes | SSH keys authorized on the box at *first boot* (NixOS AMI reads `aws_key_pair`). The full team key list is managed via NixOS config later — this is just bootstrap. |
| `ssh_ingress_cidrs` | list(string) | `["0.0.0.0/0"]` | no | Restrict who can SSH. Default mirrors agicash-mints; teams that want to lock it down to a VPN range can. |
| `allow_http` | bool | `true` | no | Whether to open 80 and 443. False for headless internal-only VPSes. |
| `extra_ingress_ports` | list(number) | `[]` | no | Additional TCP ports to open (e.g. agent-facing webhook port). Kept simple — list of ports, not full CIDR rules. |
| `nixos_ami_channel` | string | `"24.11"` | no | NixOS channel filter passed to the AMI data source (`nixos/${channel}*`). |
| `tags` | map(string) | `{}` | no | Free-form extra tags merged onto every resource. |

Things deliberately left out for v1: VPC creation (we use default VPC), subnet selection (default), IAM instance profile (no AWS calls from the box yet), Route53 (DNS managed externally), EBS data volumes (root only), multiple instances (one box per terraform apply).

The biggest delta from agicash-mints is removing `domain_name` and `project_name` defaults and consolidating to a single required `name`. `domain_name` is application-layer concern — it doesn't belong in the generic terraform.

`ssh_public_keys` is plural where agicash-mints had singular `ssh_public_key`. `aws_key_pair` itself takes one key, but you can register a synthetic "first key" for terraform's purposes and supply the full list to the NixOS config (`authorized_keys`). Equivalently, take just one bootstrap key here and let nix layer in the rest. Recommendation: take a list, use the first entry for `aws_key_pair`, and emit the full list as an output for nix to consume. This avoids duplicate key configuration between terraform and nix.

## 3. Outputs

`outputs.tf` emits the contract that the nix layer reads:

| Output | Purpose |
|---|---|
| `instance_id` | EC2 instance ID for debugging / AWS console links. |
| `public_ip` | Elastic IP. The single source of truth for "where is this box". Consumed by `deploy-config.nix`. |
| `public_dns` | AWS-assigned DNS name (`ec2-X-X-X-X.compute-1.amazonaws.com`). Useful when teams haven't pointed real DNS yet. |
| `ssh_command` | Convenience: copy-paste SSH command with the right key path hint. |
| `ssh_public_keys` | Echo of the input — lets the nix layer pull the full key list out of terraform output without re-reading tfvars. |
| `name` | Echo of `var.name` — so `terraform output -json \| jq` gives nix everything it needs in one shot. |

All outputs non-sensitive. State file holds the EIP allocation but no secrets (no IAM credentials, no passwords, no token material).

## 4. Nix integration

**Choice: `deploy-rs`.**

Justification:

- agicash-mints already runs it in production; the operator-level workflow is known to work end-to-end on AWS NixOS AMIs with Docker on the box.
- Magic rollback (auto-revert if SSH breaks post-activation) is a real safety win for a multi-user box where a bad config locks everyone out.
- It is flake-native: a `deploy` attribute on the flake, no extra config file format to learn.
- `remoteBuild = true` works fine on t3.medium for a NixOS-only build (no Rust crane build to compile, unlike agicash-mints) — and for the first agicash consumer that *does* need a Rust-ish build, it stays consistent.

Alternatives considered:

- **nixos-anywhere**: excellent for the *first* deploy onto bare metal / generic Linux. We don't need it because the NixOS AMI is already booted NixOS. Could be useful later for non-AWS targets, but doesn't earn its complexity today.
- **colmena**: similar feature set to deploy-rs, marginally more ergonomic for multi-host fleets. We have one host per deployment. No win.
- **morph**: heavier, less actively maintained.
- **Plain `nixos-rebuild --target-host`**: simplest, no extra dep. Loses magic rollback and the explicit `deploy.<name>` flake attribute we want as the standard ritual.

Verdict: deploy-rs for v1. If we hit deploy-rs friction (build perf, flake eval cost) we can fall back to `nixos-rebuild --target-host` without changing the terraform contract — the interface between terraform and nix is just "give me an IP and an SSH key path."

### Flow

```
1. cp terraform.tfvars.example terraform.tfvars && edit
2. terraform init && terraform apply
3. terraform output -raw public_ip > /tmp/ip   # or copy by hand
4. cp deploy-config.nix.example deploy-config.nix && paste IP + keys
5. nix run .#deploy.team-vps      # wraps `deploy .#team-vps` from the example dir
6. (optional) point DNS at the EIP
```

`deploy-config.nix` is the seam. It is gitignored (per agicash-mints precedent) so each operator's IP/keys stay local. The contents are exactly what agicash-mints uses: `{ hostname = "..."; sshPublicKeys = [ ... ]; }`.

The `examples/team-vps/flake.nix` will declare:

```
nixosConfigurations.team-vps = nixpkgs.lib.nixosSystem { ... };
deploy.nodes.team-vps = { hostname = deployConfig.hostname; ... };
apps.deploy = { type = "app"; program = "${deploy-rs}/bin/deploy"; };
```

Optional nicety: a `terraform-to-deploy-config` helper script in `devShells.default` that runs `terraform output -json` and pretty-prints a deploy-config.nix stub. Defer to v2 — too clever for now, plain copy-paste works.

## 5. Reproducibility

**Pinned:**
- Terraform required version: `>= 1.6`. (1.6 added the test framework; widely available.)
- AWS provider: `~> 5.0`, lockfile committed (`.terraform.lock.hcl` in git).
- NixOS AMI: looked up via data source filtered on channel name (`nixos/24.11*`). **Not** pinned to a specific AMI ID. Pinning the AMI ID is technically more reproducible but means the AMI rolls only when a human edits the variable — and the official NixOS AMI is rebuilt frequently with security patches. Bias toward "newest patch of pinned channel" via the data source. If a future deploy needs *exact* AMI reproducibility (e.g. recreating a prod incident), an operator can override by setting `ami_id` explicitly — add this as a v2 escape hatch when needed, don't preemptively add it.
- NixOS channel: pinned via `nixos_ami_channel` variable, default `"24.11"`. Bumping to `"25.05"` is a deliberate input change.

**Secrets:**

Two layers, separated by what owns them:

1. **Terraform-side**: only one input is sensitive — `ssh_public_keys`. Public keys are *not* secret, so `terraform.tfvars` doesn't actually need encryption. Keep `*.tfvars` gitignored anyway (it already is) so operators don't accidentally commit deploy-specific values.
2. **Application/runtime secrets** (Discord bot tokens, Anthropic API key, etc.): live in the *nix* layer, not terraform. Use `sops-nix` (recommended) — encrypted secrets in the repo, decryption key on each operator/box. Forge's existing `modules/forge.nix` already references `discordBotTokenFile = "/run/secrets/discord-token"` shape, which is the sops-nix convention. The forge module is already designed for sops-nix even though sops-nix isn't wired in yet. Wire it in the same PR as the actual NixOS module composition for the example — not in the terraform PR.
3. **AWS credentials**: provided to terraform via the operator's environment (`AWS_PROFILE`, `AWS_ACCESS_KEY_ID`, or `aws sso`). Never in tfvars. Document in README.

**Why not AWS Parameter Store / Secrets Manager**: adds AWS coupling for secrets that nix can decrypt locally. sops-nix keeps the deployment self-contained and offline-friendly. Revisit if we ever need runtime secret rotation without redeploying.

**State files:**

Recommendation: **local state initially, S3 backend as soon as a second person needs to apply.** Concretely:

- v1 (this PR): no backend block. State lives in `terraform/terraform.tfstate`, gitignored (already is via `*.tfstate`). Sufficient for "gudnuf applies, nobody else does."
- v2 (when needed): add `backend "s3"` block pointing at a bucket like `s3://makeprisms-tf-state/team-vps/<name>.tfstate` with DynamoDB locking. The bootstrap for that bucket is a separate one-time terraform apply that lives outside this directory (cycle problem otherwise).

The README should explicitly note this trade-off so the next operator doesn't get surprised.

## 6. Ephemeral path

The cleanest separation for "spin up a throwaway test box" is **a sibling example directory**, not workspaces.

Proposed shape (not in this PR — proposed for a follow-up):

```
examples/
  team-vps/           # long-lived production-ish deployment
    terraform/
    flake.nix
    configuration.nix
  ephemeral-vps/      # spin-up-and-tear-down test box
    terraform/        # imports the same future module, different defaults
    flake.nix
    configuration.nix
```

Why sibling example over `terraform workspace new ephemeral`:

- Workspaces share state file and `*.tf` code but vary `terraform.workspace`-conditional values. They're ergonomic for "prod vs staging of the same service." They're a poor fit for "an ad-hoc test box that should disappear in two hours" because the conditional logic spreads through `main.tf`.
- A sibling example keeps the ephemeral path **its own thing** with its own tfvars defaults (smaller instance, shorter EIP lifetime, maybe no EIP at all to save cost).
- It also makes the README story clean: "for prod, use team-vps. For a throwaway, use ephemeral-vps."

Path to the ephemeral example (in a future PR):

1. Extract `examples/team-vps/terraform/` into `modules/terraform/aws-nixos-vps/` (promote to a child module once we have a second caller).
2. `examples/team-vps/terraform/main.tf` becomes a thin caller.
3. `examples/ephemeral-vps/terraform/main.tf` is the second caller, with `instance_type = "t3.small"`, no EIP (or a flag to skip the EIP resource), shorter retention tags.

What changes about *this* PR to make that future cheap:

- Use generic resource names (`aws_instance.this`, not `aws_instance.team_vps`).
- Make `allow_http` / `ssh_ingress_cidrs` / `extra_ingress_ports` variables so the ephemeral case can lock things down without forking.
- Don't bake `Project = "team-vps"` into tags — derive from `var.name`.

If those are honored, the future child-module extraction is mechanical.

Optional v1 ergonomics for *destruction speed* on the team-vps box itself (since "ephemeral-ready" implies we should be able to tear down too): document that `terraform destroy` leaves no orphan resources, and add a tag `ManagedBy = "terraform"` so cost-audit scripts can find stragglers.

## 7. Open questions

Before implementation, the following decisions need gudnuf's call:

1. **Single bootstrap key vs. full team key list in terraform?** Recommendation above: take a list, register first key in `aws_key_pair`, expose full list as output for nix. Confirm this is the right split, or whether terraform should only know about one bootstrap key and nix handles all team keys.
2. **`name` semantics — what's the canonical example value?** Plan assumes the agicash-team consumer calls it something like `agicash-team-vps`. Any naming conventions to bake into the README example?
3. **Region default — `us-east-1` or no default?** agicash-mints defaults to `us-east-1`; the IAM policy is region-scoped to `us-east-1`. Forge generic might want no default to force the operator to choose. Recommendation: keep `us-east-1` default for ergonomic parity, document the IAM-policy-must-match constraint in README.
4. **EIP always-on?** EIPs cost ~$3.60/mo while unattached. For ephemeral use this is annoying. v1 keeps EIP always — should we add `allocate_eip = bool` (default true) now or wait for the ephemeral PR? Recommendation: add the variable now, default true. One line, zero cost.
5. **`extra_ingress_ports` model**: list of TCP ports with `0.0.0.0/0` only, or richer (per-port CIDR allowlist)? Recommendation: start with `list(number)`, all 0.0.0.0/0. Promote to objects when a real use case appears.
6. **Root volume size**: 30GB enough for a multi-user nix store with 3-5 keepers? Or should we plan for 50GB+ by default? Empirical question — what's the agicash-mints box actually using today? Recommendation: 30GB default, document how to bump.
7. **Provider version pin**: `~> 5.0` matches agicash-mints. Pin tighter (`~> 5.70`) to lock minor version, looser (`>= 5.0`) for flexibility? Recommendation: `~> 5.0` like agicash-mints. Lockfile committed handles the tight pin in practice.
8. **deploy-rs vs. plain `nixos-rebuild --target-host` for the absolute first deploy?** Magic rollback only protects activation, not initial install. Recommendation: deploy-rs from day one for consistency, even if the very first apply needs an extra `--skip-checks` or similar.
9. **sops-nix wiring location**: does the secrets bootstrap (admin key, age key generation) belong in `examples/team-vps/` README, or in a forge-level doc? Out of scope for this terraform PR but flagging it so it doesn't get lost.

## Summary

- **Mirror agicash-mints structure** (`main.tf` / `variables.tf` / `outputs.tf` / `versions.tf` / `iam-policy.json` / `terraform.tfvars.example` / `README.md`) under `examples/team-vps/terraform/`, but with generic resource names (`aws_instance.this`) and no agicash-specific defaults so the same code serves any deployment.
- **Variables stay minimal and explicit**: `name`, `aws_region`, `instance_type`, `root_volume_size`, `ssh_public_keys` (list), `ssh_ingress_cidrs`, `allow_http`, `extra_ingress_ports`, `nixos_ami_channel`, `tags`. Nothing application-specific (no `domain_name`).
- **deploy-rs stays as the nix push tool** — same as agicash-mints — chosen for magic rollback and flake-native ergonomics. Terraform output `public_ip` feeds into a gitignored `deploy-config.nix`; then `nix run .#deploy.team-vps` activates the system.
- **State is local now, S3 backend later** when a second operator needs to apply; AMI tracks `nixos/24.11*` data-source filter rather than a hardcoded AMI ID; provider pinned `~> 5.0` with lockfile committed; secrets stay out of terraform entirely (public SSH keys only) and runtime secrets go through sops-nix in the nix layer.
- **Ephemeral path is a sibling example, not a workspace**: `examples/ephemeral-vps/` lands in a later PR and reuses an extracted child module under `modules/terraform/aws-nixos-vps/`. This PR is shaped to make that future extraction mechanical: generic resource names, no hardcoded `Project` tags, and ingress configurability already parameterized.
