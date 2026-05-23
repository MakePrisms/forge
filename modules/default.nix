{ config, lib, pkgs, ... }:

# Composition root.
#
# Each concern lives in its own sibling module:
#   ./users.nix    — Linux users, SSH keys, shared forge group
#   ./discord.nix  — Discord identity (extends the user submodule)
#
# Adding a new concern (e.g. pikachat keypair per user) means a new
# sibling module + one line in `imports` here. default.nix stays small.

{
  imports = [
    ./users.nix
    ./discord.nix
  ];

  options.services.forge = {
    enable = lib.mkEnableOption "forge agent system";
  };
}
