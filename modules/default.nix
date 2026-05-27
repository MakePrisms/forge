{ config, lib, pkgs, ... }:

{
  imports = [
    ./users.nix
    ./discord.nix
    ./agents.nix
    ./secrets.nix
  ];

  options.services.forge = {
    enable = lib.mkEnableOption "forge agent system";
  };
}
