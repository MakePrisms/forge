{ config, lib, ... }:

# Discord integration: declare bots once at the top level, reference
# them by name from individual agents.
#
# Many agents can share one bot identity ("team"), or each specialist
# can have its own bot — the choice is a deployment decision, not a
# substrate one. Bots are first-class so the same pattern works for
# both.

let
  cfg = config.services.forge;
in
{
  # Shared Discord-bot manifest. Each entry is a distinct Discord
  # application with its own identity and token. Agents reference
  # bots by name.
  options.services.forge.discord.bots = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        tokenFile = lib.mkOption {
          type = lib.types.str;
          description = ''
            Path to a file containing this bot's Discord token.
            Typically managed by sops-nix and readable only by the
            users whose agents reference this bot.
          '';
          example = "/run/secrets/team-bot-token";
        };
      };
    });
    default = { };
    description = ''
      Discord bots available to forge agents. Each bot is a distinct
      Discord application with its own identity. Agents reference
      bots by name in their `discordBot` option.

      Start with one shared bot; split into per-specialist bots as
      trust isolation matures.
    '';
    example = lib.literalExpression ''
      {
        team = { tokenFile = "/run/secrets/team-bot-token"; };
      }
    '';
  };

  # Extends services.forge.agents.<name> with `discordBot` — selects
  # which bot identity this agent uses. Must reference a bot declared
  # in services.forge.discord.bots.
  options.services.forge.agents = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        discordBot = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            Name of the Discord bot this agent uses, drawn from
            services.forge.discord.bots. Null means this agent has
            no Discord presence.
          '';
          example = "team";
        };
      };
    });
  };

  config = lib.mkIf cfg.enable {
    # Every agent's discordBot reference must point to a declared bot.
    assertions = lib.mapAttrsToList
      (name: agent: {
        assertion = agent.discordBot == null
          || builtins.hasAttr agent.discordBot cfg.discord.bots;
        message = ''
          services.forge.agents.${name}.discordBot = "${toString agent.discordBot}"
          but "${toString agent.discordBot}" is not declared in
          services.forge.discord.bots. Declare the bot first or correct
          the reference.
        '';
      })
      cfg.agents;
  };
}
