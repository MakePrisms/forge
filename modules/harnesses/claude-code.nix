{ config, lib, pkgs, claudeCode, ... }:

# claude-code harness: turns declared agents into running processes.
#
# For each services.forge.agents.<name> with harness = "claude-code":
#   1. The shared forge library is installed once into /etc/forge/:
#        - skills  → /etc/forge/skill-library/<name>/  (from services.forge.skills)
#        - plugins → /etc/forge/plugin-library/<name>/ (from services.forge.plugins)
#      MCP servers don't need an install path — they're transcribed by
#      command + args directly into each agent's .mcp.json.
#   2. A wrapper script `forge-agent-<name>` builds the agent's per-CWD
#      environment on every start (CLAUDE.md, .claude/skills/ symlinks,
#      .claude/settings.json, .claude/skill-catalog.md, .mcp.json, .env)
#      then execs claude-code through a shared tmux server.
#   3. A systemd service runs each agent under its declared runAs user,
#      supervised with restart-on-failure and start-rate limit.
#   4. claude-code + tmux + jq installed system-wide so any operator can
#      attach or invoke wrappers manually.
#
# Per-agent isolation (see docs/per-agent-environment-design.md):
#   The wrapper assembles the agent's CWD from the declared whitelist —
#   only the skills/plugins/MCP servers the agent has opted into appear.
#   The library at /etc/forge/ is shared; the symlinks/files inside each
#   per-agent CWD are not.
#
# Operator cheat sheet (on the box):
#   systemctl start forge-agent-<name>          # start
#   systemctl status forge-agent-<name>         # state
#   journalctl -u forge-agent-<name> -f         # logs
#   sudo -u <runAs> tmux -L forge attach -t agent-<name>   # attach
#   sudo -u <runAs> tmux -L forge ls            # list all agents on this user

let
  cfg = config.services.forge;

  claudeAgents =
    lib.filterAttrs (_: a: a.harness == "claude-code") cfg.agents;

  # --- Shared library install paths (referenced by both etc/ and wrappers) ---
  skillLibraryDir = "/etc/forge/skill-library";
  pluginLibraryDir = "/etc/forge/plugin-library";

  # --- Per-agent generated files (built at evaluation time, copied at start) ---

  # CLAUDE.md from declared role.
  mkClaudeMd = name: agent:
    pkgs.writeText "CLAUDE-${name}.md" ''
      # ${name}

      ${agent.role}
    '';

  # .mcp.json — only declared MCP servers, in claude-code's native shape.
  # ALWAYS write the file (even with an empty mcpServers map) because
  # --mcp-config errors on missing files.
  mkMcpJson = name: agent:
    let
      selected = lib.listToAttrs (map
        (server: lib.nameValuePair server (
          let s = cfg.mcpServers.${server}; in
          {
            inherit (s) command args;
          } // (lib.optionalAttrs (s.env != { }) { inherit (s) env; })
        ))
        agent.mcpServers);
    in
    pkgs.writeText "mcp-${name}.json" (builtins.toJSON {
      mcpServers = selected;
    });

  # .claude/settings.json — permission allow/deny carried from the schema.
  # Actual permission gating today is bypassed by --dangerously-skip-permissions;
  # the file exists so the seam is in place for the scoped-permissions follow-up.
  mkSettingsJson = name: agent:
    pkgs.writeText "settings-${name}.json" (builtins.toJSON {
      permissions = {
        allow = agent.permissions.allow;
        deny = agent.permissions.deny;
      };
    });

  # .claude/skill-catalog.md — one-line description per declared skill,
  # appended to the agent's system prompt so it knows what's available
  # without us loading every skill body into context.
  mkSkillCatalog = name: agent:
    let
      body =
        if agent.skills == [ ]
        then ""
        else lib.concatMapStrings
          (skill: "- /${skill} — ${cfg.skills.${skill}.description}\n")
          agent.skills;
    in
    pkgs.writeText "skill-catalog-${name}.md" ''
      # Available skills

      ${body}'';

  # Wrapper script. Builds the per-agent CWD on every start, then execs
  # claude-code inside tmux.
  mkWrapper = name: agent:
    let
      claudeMd = mkClaudeMd name agent;
      mcpJson = mkMcpJson name agent;
      settingsJson = mkSettingsJson name agent;
      skillCatalog = mkSkillCatalog name agent;

      hasDiscord = agent.discordBot != null;
      tokenFile =
        if hasDiscord then cfg.discord.bots.${agent.discordBot}.tokenFile else "";

      # --plugin-dir flags — one per declared plugin name. The harness
      # points at /etc/forge/plugin-library/<name>/ which environment.etc
      # populates from the declared `source`.
      pluginDirArgs = lib.concatMapStringsSep " "
        (plugin: ''--plugin-dir "${pluginLibraryDir}/${plugin}"'')
        agent.plugins;

      # --allowedTools — single comma-separated arg. Only emitted when
      # the list is non-empty; an empty --allowedTools "" would strip the
      # built-in tool surface (see spec "corrections from technical review").
      allowedToolsFlag =
        if agent.allowedTools == [ ]
        then ""
        else ''--allowedTools "${lib.concatStringsSep "," agent.allowedTools}"'';
    in
    pkgs.writeShellApplication {
      name = "forge-agent-${name}";
      runtimeInputs = [ pkgs.tmux pkgs.jq pkgs.coreutils claudeCode ];
      text = ''
        set -euo pipefail

        STATE_DIR="$HOME/.local/state/forge/agents/${name}"

        # Per-agent skill symlinks live under .claude/skills/. Wipe the
        # whole subtree on every start so removing a skill from the
        # config actually removes the symlink from the agent's view; then
        # recreate from scratch with the current whitelist.
        rm -rf "$STATE_DIR/.claude/skills"
        mkdir -p "$STATE_DIR/.claude/skills"
        ${lib.concatMapStrings
          (skill: ''
            ln -sf "${skillLibraryDir}/${skill}" "$STATE_DIR/.claude/skills/${skill}"
          '')
          agent.skills}

        # Refresh per-agent generated files from the declaration. All are
        # sourced from the Nix store (immutable) and copied into the
        # agent's writable CWD so claude-code can read them without
        # special-casing store paths.
        cp -f "${claudeMd}"     "$STATE_DIR/CLAUDE.md"
        cp -f "${mcpJson}"      "$STATE_DIR/.mcp.json"
        cp -f "${settingsJson}" "$STATE_DIR/.claude/settings.json"
        cp -f "${skillCatalog}" "$STATE_DIR/.claude/skill-catalog.md"

        ${lib.optionalString hasDiscord ''
          # Plumb the discord plugin: read the bot token from the secret
          # file and write a per-agent .env. The claude discord plugin
          # consumes DISCORD_BOT_TOKEN from $DISCORD_STATE_DIR/.env.
          if [ -f "${tokenFile}" ]; then
            printf 'DISCORD_BOT_TOKEN=%s\n' "$(cat "${tokenFile}")" > "$STATE_DIR/.env"
            chmod 600 "$STATE_DIR/.env"
          else
            echo "WARN: discord bot token file ${tokenFile} not found; starting without discord" >&2
          fi
          export DISCORD_STATE_DIR="$STATE_DIR"
        ''}

        cd "$STATE_DIR"

        # claude-code is interactive — it needs a PTY. tmux provides the
        # PTY and makes the session attachable. Shared "forge" socket so
        # `tmux -L forge ls` enumerates every agent on this user.
        #
        # NOTE: --bare is intentionally NOT used (it disables OAuth/keychain
        # reads, breaking subscription auth). --strict-mcp-config is also
        # NOT used (it strips plugin-bundled MCP servers). See spec for the
        # full justification of each flag.
        exec tmux -L forge new-session -A -s "agent-${name}" \
          claude \
            --model "${agent.model}" \
            --effort max \
            --mcp-config .mcp.json \
            ${pluginDirArgs} \
            --settings .claude/settings.json \
            --setting-sources project \
            --append-system-prompt-file .claude/skill-catalog.md \
            --dangerously-skip-permissions \
            ${allowedToolsFlag}
      '';
    };

  mkUnit = name: agent: {
    description = "Forge agent: ${name}";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      User = agent.runAs;
      Group = "forge";
      ExecStart = "${mkWrapper name agent}/bin/forge-agent-${name}";
      Restart = "on-failure";
      RestartSec = "5s";
      StartLimitBurst = 3;
      StartLimitIntervalSec = 60;
    };
  };

  # /etc/forge/skill-library/<name>/ from services.forge.skills.
  skillEtc = lib.mapAttrs'
    (skill: s: lib.nameValuePair
      "forge/skill-library/${skill}"
      { source = s.source; })
    cfg.skills;

  # /etc/forge/plugin-library/<name>/ from services.forge.plugins.
  pluginEtc = lib.mapAttrs'
    (plugin: p: lib.nameValuePair
      "forge/plugin-library/${plugin}"
      { source = p.source; })
    cfg.plugins;

in
{
  config = lib.mkIf cfg.enable (lib.mkMerge [
    # Always install claude-code + tmux when forge is enabled, so operators
    # have them whether or not any agent is declared yet.
    {
      environment.systemPackages = [ claudeCode pkgs.tmux ];

      # Shared library installation. Attrset uniqueness is enforced at
      # parse time, so duplicate library names can't reach this point —
      # the defensive assertion below covers the same ground explicitly
      # for anyone reading the eval output.
      environment.etc = skillEtc // pluginEtc;

      # Eval-time sanity assertion. Nix attrsets enforce uniqueness on
      # their own, but a named assertion produces a better error message
      # if someone tries to merge configs with overlapping library entries
      # via lib.mkMerge.
      assertions = [
        {
          assertion =
            (lib.length (lib.attrNames cfg.skills))
              == (lib.length (lib.unique (lib.attrNames cfg.skills)));
          message = "services.forge.skills has duplicate entries (this should be impossible — file a bug).";
        }
        {
          assertion =
            (lib.length (lib.attrNames cfg.plugins))
              == (lib.length (lib.unique (lib.attrNames cfg.plugins)));
          message = "services.forge.plugins has duplicate entries (this should be impossible — file a bug).";
        }
        {
          assertion =
            (lib.length (lib.attrNames cfg.mcpServers))
              == (lib.length (lib.unique (lib.attrNames cfg.mcpServers)));
          message = "services.forge.mcpServers has duplicate entries (this should be impossible — file a bug).";
        }
      ];
    }

    # Per-agent: systemd service + wrapper installed in systemPackages so
    # `forge-agent-<name>` is available on PATH for manual invocation too.
    (lib.mkIf (claudeAgents != { }) {
      environment.systemPackages =
        lib.mapAttrsToList mkWrapper claudeAgents;

      systemd.services = lib.mapAttrs'
        (name: agent: lib.nameValuePair "forge-agent-${name}" (mkUnit name agent))
        claudeAgents;
    })
  ]);
}
