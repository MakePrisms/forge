{ config, lib, pkgs, sshPublicKeys, ... }:

# Minimal bootable NixOS configuration for the agicash team forge VPS.
#
# What this file does:
#   - Names the box (agicash-team-forge)
#   - Enables flakes (required for deploy-rs remoteBuild)
#   - Opens the firewall for SSH/HTTP/HTTPS
#   - Authorizes root SSH with the operator's keys (bootstrap)
#   - Turns on the forge module and declares gudnuf as the first forge user
#
# The exact list of operator SSH keys is supplied by deploy-config.nix (the
# per-operator seam, gitignored). It is plumbed in via specialArgs from the
# root flake as `sshPublicKeys`.
#
# Application/runtime secrets (Discord bot tokens, Anthropic API key, etc.)
# are NOT wired here — they belong in a follow-up via sops-nix.

{
  system.stateVersion = "24.11";
  networking.hostName = "agicash-team-forge";

  # Flakes required for deploy-rs remoteBuild (the build happens on the box).
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # --- Firewall ---
  networking.firewall.allowedTCPPorts = [ 22 80 443 ];

  # CRITICAL: Docker veth interfaces get link-local routes that override the
  # 169.254.169.254 EC2 metadata endpoint. Deny them from dhcpcd.
  # See: https://github.com/NixOS/nixpkgs/issues/109389
  networking.dhcpcd.denyInterfaces = [ "veth*" ];

  # Disable amazon-init — it reads EC2 userdata and can run nixos-rebuild
  # switch, potentially overwriting our deploy-rs configuration.
  virtualisation.amazon-init.enable = false;

  # --- SSH ---
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  # Root retains the operator keys so deploy-rs (which runs as root) can SSH in.
  # Per-user keys for forge users are managed via services.forge.users below.
  users.users.root.openssh.authorizedKeys.keys = sshPublicKeys;

  # --- forge ---
  services.forge.enable = true;

  # First forge user. The placeholder key list comes from deploy-config.nix
  # via specialArgs; refine this once per-user key partitioning is decided.
  services.forge.users.gudnuf = {
    sshKeys = sshPublicKeys;
  };

  # --- Nix GC ---
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
}
