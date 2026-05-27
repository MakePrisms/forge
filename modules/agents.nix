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

        # --- Per-agent isolation whitelist (see docs/per-agent-environment-design.md) ---
        # Each list references shared library entries by name. The harness
        # assembles the per-agent CWD from these whitelists on every start.

        skills = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = ''
            Names of skills (from services.forge.skills) this agent has
            access to. Each declared skill is symlinked into the agent's
            per-CWD `.claude/skills/<name>` and listed in the agent's
            skill-catalog (appended to its system prompt).

            Skills not in this list are not invocable and not visible to
            the agent's planner.
          '';
          example = lib.literalExpression ''[ "discord-tools" "verify" ]'';
        };

        mcpServers = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = ''
            Names of MCP servers (from services.forge.mcpServers) this
            agent has access to. Each declared server is written into the
            agent's per-CWD `.mcp.json`; servers not in this list are not
            launched and their tools never appear in the model's surface.
          '';
          example = lib.literalExpression ''[ "playwright" "mercury" ]'';
        };

        plugins = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = ''
            Names of claude-code plugins (from services.forge.plugins)
            this agent has access to. The harness adds a `--plugin-dir`
            flag pointing at /etc/forge/plugin-library/<name>/ for each
            entry; the plugin's bundled MCP servers register with the
            `mcp__plugin_<name>_<server>__` tool prefix.
          '';
          example = lib.literalExpression ''[ "discord" ]'';
        };

        allowedTools = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = ''
            Tool surface this agent is told it has, in claude-code's
            --allowedTools syntax (e.g. "Bash(git *)", "Edit", "Read",
            "mcp__plugin_discord_discord__reply"). Controls which tools
            the model knows about and emits in tool-call grammar — distinct
            from permission gating, which today is bypassed via
            --dangerously-skip-permissions.

            Empty list means no --allowedTools flag is passed; the model
            sees the harness defaults plus any plugin/MCP-contributed tools.
          '';
          example = lib.literalExpression ''
            [ "Bash(git *)" "Edit" "Read" "mcp__mercury__send" ]
          '';
        };

        permissions = lib.mkOption {
          type = lib.types.submodule {
            options = {
              allow = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = ''
                  Tool-call patterns the agent is allowed to invoke without
                  prompting. Written to the per-agent .claude/settings.json.
                  Today the harness passes --dangerously-skip-permissions,
                  so this list is advisory; the schema seam exists for the
                  scoped-permissions follow-up.
                '';
              };

              deny = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = ''
                  Tool-call patterns the agent must never invoke. Same
                  caveats as `allow` — schema seam pending the scoped-
                  permissions follow-up.
                '';
              };

              skipPrompts = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = ''
                  Reserved for the scoped-permissions follow-up. Today the
                  harness always passes --dangerously-skip-permissions; this
                  flag has no effect yet but is declared so callers can
                  start setting it and the harness can flip behavior when
                  the policy work lands.
                '';
              };
            };
          };
          default = { };
          description = ''
            Per-agent permission policy. Schema only at this stage — see
            docs/per-agent-environment-design.md "Non-goals" for the
            scoped-permissions deferral.
          '';
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
          discordBot = "team";
        };
      }
    '';
  };

  config = lib.mkIf cfg.enable {
    # Cross-cutting validation: every agent's runAs must reference a
    # declared forge user, and every library reference (skills, mcpServers,
    # plugins) must point to a declared library entry. Catches typos at
    # evaluation time instead of at session-start time.
    assertions =
      let
        runAsChecks = lib.mapAttrsToList
          (name: agent: {
            assertion = builtins.hasAttr agent.runAs cfg.users;
            message = ''
              services.forge.agents.${name}.runAs = "${agent.runAs}" but
              "${agent.runAs}" is not declared in services.forge.users.
              Declare the user first, or correct the runAs.
            '';
          })
          cfg.agents;

        libraryRefChecks = lib.concatLists (lib.mapAttrsToList
          (name: agent:
            (map
              (skill: {
                assertion = builtins.hasAttr skill cfg.skills;
                message = ''
                  services.forge.agents.${name}.skills references "${skill}"
                  but "${skill}" is not declared in services.forge.skills.
                  Declare the skill in the library first, or correct the
                  reference.
                '';
              })
              agent.skills)
            ++ (map
              (server: {
                assertion = builtins.hasAttr server cfg.mcpServers;
                message = ''
                  services.forge.agents.${name}.mcpServers references
                  "${server}" but "${server}" is not declared in
                  services.forge.mcpServers. Declare the server in the
                  library first, or correct the reference.
                '';
              })
              agent.mcpServers)
            ++ (map
              (plugin: {
                assertion = builtins.hasAttr plugin cfg.plugins;
                message = ''
                  services.forge.agents.${name}.plugins references
                  "${plugin}" but "${plugin}" is not declared in
                  services.forge.plugins. Declare the plugin in the
                  library first, or correct the reference.
                '';
              })
              agent.plugins))
          cfg.agents);
      in
      runAsChecks ++ libraryRefChecks;

    # Implementation (wrapper scripts, systemd services, harness wiring)
    # lives in sibling modules — kept here to declarations only so the
    # team can extend with their own concerns without touching this file.
  };
}
