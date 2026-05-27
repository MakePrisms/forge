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
# are encrypted in `secrets.yaml` (gitignored) and decrypted at activation
# by sops-nix into `/run/secrets/<name>`. Plumbing defaults live in
# `modules/secrets.nix`; per-deployment secret declarations live below
# (commented out until the operator has run the bootstrap in
# `docs/secrets-bootstrap.md`).

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

  # --- Secrets + first agent (uncomment after bootstrap) ---
  #
  # The forge `modules/secrets.nix` module wires sops-nix plumbing in
  # the background. To start using encrypted secrets and the first
  # agent:
  #   1. Follow docs/secrets-bootstrap.md to generate an age key,
  #      register it in .sops.yaml, and create the encrypted
  #      secrets.yaml file containing `team-bot-token`.
  #   2. Uncomment the block below: it declares the secret, the
  #      Discord bot that consumes it, and the first agent that uses
  #      the bot.
  #   3. Redeploy. systemd starts `forge-agent-coordinator` on boot;
  #      the agent joins Discord and responds to @mentions.
  #
  # sops.secrets."team-bot-token" = {
  #   owner = "gudnuf";
  # };
  #
  # services.forge.discord.bots.team = {
  #   tokenFile = config.sops.secrets."team-bot-token".path;
  # };
  #
  # services.forge.agents.coordinator = {
  #   role = ''
  #     agicash team coordinator — the on-call agent in the team
  #     Discord channel. Listen for @mentions, respond helpfully,
  #     and learn the team's workflows as we collaborate.
  #   '';
  #   runAs = "gudnuf";
  #   discordBot = "team";
  # };

  # --- Nix GC ---
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
}
