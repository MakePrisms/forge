{ config, lib, pkgs, ... }:

let
  cfg = config.services.forge;

  # Each forge user gets their own Linux account and home dir — their "locus
  # of control." They also join the shared `forge` group, used for collaborative
  # directories under /srv/forge/.
  userType = lib.types.submodule {
    options = {
      sshKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "SSH public keys authorized for this user.";
        example = lib.literalExpression ''
          [ "ssh-ed25519 AAAA... gudnuf@laptop" ]
        '';
      };

      botTokenFile = lib.mkOption {
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
  };
in
{
  options.services.forge = {
    enable = lib.mkEnableOption "forge agent system";

    users = lib.mkOption {
      type = lib.types.attrsOf userType;
      default = { };
      description = ''
        Forge users. Each entry becomes a Linux user with their own home dir,
        member of the shared `forge` group.
      '';
      example = lib.literalExpression ''
        {
          gudnuf = {
            sshKeys = [ "ssh-ed25519 ..." ];
            botTokenFile = "/run/secrets/gudnuf-bot-token";
          };
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Shared group for collaborative directories.
    users.groups.forge = { };

    # Provision each declared forge user.
    users.users = lib.mapAttrs
      (name: userCfg: {
        isNormalUser = true;
        extraGroups = [ "forge" ];
        openssh.authorizedKeys.keys = userCfg.sshKeys;
      })
      cfg.users;
  };
}
