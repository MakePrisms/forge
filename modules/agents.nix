{ config, lib, pkgs, ... }:

# Per-agent definitions.
#
# Each entry under `services.forge.agents.<name>` declares a persistent
# agent identity — a role, a harness, a model, and the Linux user it
# runs under. Sessions (running instances of the agent) are spawned
# from this declaration; the identity itself outlives any one session.
#
# Sibling modules (e.g. ./discord.nix, future harness/comms modules)
# contribute additional options to the agent submodule via NixOS
# option merging — same pattern as services.forge.users.
#
# Intentionally minimal at this stage. Options for thinking depth,
# memory directories, permission profiles, mercury identity,
# multi-harness selection, etc. land in sibling modules as the team
# designs them — not pre-baked here.

let
  cfg = config.services.forge;
in
{
  options.services.forge.agents = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        role = lib.mkOption {
          type = lib.types.str;
          description = ''
            What this agent is for, in one sentence. Loaded as the agent's
            top-line role definition when its session starts.
          '';
          example = "agicash team coordinator";
        };

        harness = lib.mkOption {
          type = lib.types.enum [ "claude-code" ];
          default = "claude-code";
          description = ''
            Which harness this agent runs in. Currently only claude-code
            is supported; codex and others will be added as separate
            harness modules.
          '';
        };

        model = lib.mkOption {
          type = lib.types.str;
          default = "opus-4.7";
          description = ''
            Which model the harness invokes. Format depends on the harness
            (claude-code accepts model aliases like "opus-4.7", "sonnet-4.6",
            "haiku-4.5").
          '';
        };

        runAs = lib.mkOption {
          type = lib.types.str;
          description = ''
            Linux user this agent runs as. Must be a user declared in
            services.forge.users — that user's home dir is where the
            agent's session lives, and its trust gradient is inherited
            from the user's permissions.
          '';
          example = "gudnuf";
        };
      };
    });
    default = { };
    description = ''
      Forge agents. Each entry is a persistent agent identity — a name
      bound to a role, a harness, a model, and a runtime user.

      Additional per-agent options (discord bot binding, future mercury
      identity, memory dirs, permission profiles, etc.) are contributed
      by sibling modules via NixOS submodule merging.
    '';
    example = lib.literalExpression ''
      {
        coordinator = {
          role = "agicash team coordinator";
          runAs = "gudnuf";
          discordBotTokenFile = "/run/secrets/team-bot-token";
        };
      }
    '';
  };

  config = lib.mkIf cfg.enable {
    # Cross-cutting validation: every agent's runAs must reference a
    # declared forge user. Catches typos at evaluation time instead of
    # at session-start time.
    assertions = lib.mapAttrsToList
      (name: agent: {
        assertion = builtins.hasAttr agent.runAs cfg.users;
        message = ''
          services.forge.agents.${name}.runAs = "${agent.runAs}" but
          "${agent.runAs}" is not declared in services.forge.users.
          Declare the user first, or correct the runAs.
        '';
      })
      cfg.agents;

    # Implementation (wrapper scripts, systemd services, harness wiring)
    # lives in sibling modules — kept here to declarations only so the
    # team can extend with their own concerns without touching this file.
  };
}
