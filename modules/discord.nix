{ config, lib, ... }:

let
  cfg = config.services.forge;
in
{
  # Extends services.forge.users.<name> with discordBotTokenFile via submodule merging.
  options.services.forge.users = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        discordBotTokenFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            Path to a file containing this user's Discord bot token.
            Typically managed by sops-nix and readable only by the user.
          '';
          example = "/run/secrets/gudnuf-bot-token";
        };
      };
    });
  };

  # System-level Discord config.
  config = lib.mkIf cfg.enable { };
}
