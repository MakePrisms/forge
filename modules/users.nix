{ config, lib, pkgs, ... }:

# Per-user provisioning.
#
# Each entry under `services.forge.users.<name>` becomes a Linux user
# with their own home dir — their "locus of control" — and joins the
# shared `forge` group used for collaborative directories under /srv/forge/.
#
# Sibling modules (e.g. ./discord.nix) contribute additional options to
# the user submodule via NixOS option merging.

let
  cfg = config.services.forge;
in
{
  options.services.forge.users = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        sshKeys = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "SSH public keys authorized for this user.";
          example = lib.literalExpression ''
            [ "ssh-ed25519 AAAA... gudnuf@laptop" ]
          '';
        };
      };
    });
    default = { };
    description = ''
      Forge users. Each entry becomes a Linux user with their own home dir,
      member of the shared `forge` group.

      Additional per-user options are contributed by sibling modules via
      NixOS submodule merging.
    '';
    example = lib.literalExpression ''
      {
        gudnuf = {
          sshKeys = [ "ssh-ed25519 ..." ];
        };
      }
    '';
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
