{ config, lib, pkgs, ... }:

{
  imports = [
    ./users.nix
    ./discord.nix
    ./agents.nix
    ./secrets.nix
    ./skills.nix
    ./mcp-servers.nix
    ./plugins.nix
    ./harnesses/claude-code.nix
  ];

  options.services.forge = {
    enable = lib.mkEnableOption "forge agent system";
  };
}
