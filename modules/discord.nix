{ config, lib, ... }:

let
  cfg = config.services.forge;
in
{
  # Contribute Discord-specific options to the per-user submodule defined
  # in ./default.nix. NixOS merges the two `services.forge.users` option
  # declarations: this module adds discordBotTokenFile to each user.
  options.services.forge.users = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        discordBotTokenFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            Path to a file containing this user's Discord bot token.
            Typically managed by sops-nix and readable only by the user.
            Declared here for future wiring — no service consumes it yet.
          '';
          example = "/run/secrets/gudnuf-bot-token";
        };
      };
    });
  };

  # System-level Discord wiring will land here when we add per-user
  # token materialization, MCP plugin setup, or bot supervision services.
  config = lib.mkIf cfg.enable {
    # intentionally empty
  };
}
