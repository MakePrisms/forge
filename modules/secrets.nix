{ config, lib, pkgs, ... }:

# Secrets plumbing — opinionated defaults on top of sops-nix.
#
# sops-nix itself is added to the system via the flake (see flake.nix:
# `sops-nix.nixosModules.sops` in the module list). This file does NOT
# import it — its job is to set sensible forge-wide defaults so each
# deployment can declare encrypted secrets without ceremony.
#
# What this module does:
#   - Defaults `sops.defaultSopsFile` to a deployment-local `secrets.yaml`
#     if the deployment hasn't set one. Deployments can override.
#   - Defaults `sops.age.keyFile` to `/var/lib/sops-nix/key.txt`, which
#     is the path operators bootstrap once per box (see
#     docs/secrets-bootstrap.md).
#
# What this module does NOT do:
#   - Declare any secrets. Secrets are deployment-specific and belong
#     in `deployments/<name>/configuration.nix` under `sops.secrets.*`.
#   - Wire secret paths into other forge modules (e.g.
#     services.forge.discord.bots.<name>.tokenFile). That stays the
#     deployment's choice — typically pointing at
#     `config.sops.secrets."<name>".path` once the secret is declared.
#
# References:
#   - https://github.com/Mic92/sops-nix
#   - docs/terraform-plan.md §5 (Secrets layer ownership)

let
  cfg = config.services.forge;
in
{
  config = lib.mkIf cfg.enable {
    # Default the per-deployment sops file path. A deployment can
    # override this with `sops.defaultSopsFile = ./secrets.yaml;` (or
    # any absolute path). The default below uses the hostname, which
    # matches the `deployments/<name>/` convention.
    sops.defaultSopsFile = lib.mkDefault
      (../deployments + "/${config.networking.hostName}/secrets.yaml");

    # Age key location on the box. Operators copy their age private key
    # here once during initial bootstrap (see docs/secrets-bootstrap.md).
    # sops-nix reads this file at activation time to decrypt secrets
    # into /run/secrets/.
    sops.age.keyFile = lib.mkDefault "/var/lib/sops-nix/key.txt";
  };
}
