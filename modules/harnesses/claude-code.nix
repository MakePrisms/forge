{ config, lib, pkgs, claudeCode, ... }:

# claude-code harness: turns declared agents into running processes.
#
# For each services.forge.agents.<name> with harness = "claude-code":
#   1. A wrapper script `forge-agent-<name>` that:
#      - Ensures the agent's state dir exists (~/.local/state/forge/agents/<name>)
#      - Writes CLAUDE.md from the declared role
#      - If discordBot is set, reads the bot token from the secret file and
#        wires a .env + DISCORD_STATE_DIR for the claude discord plugin
#      - Execs claude-code through a shared tmux server (socket: "forge")
#        for PTY + attachability. claude-code needs a TTY; tmux provides it
#        and makes the running session attachable.
#   2. A system systemd service running under the runAs user, supervised
#      with restart-on-failure and start-rate limit.
#   3. claude-code + tmux + jq installed system-wide so any operator can
#      attach or invoke wrappers manually.
#
# Operator cheat sheet (on the box):
#   systemctl start forge-agent-<name>          # start
#   systemctl status forge-agent-<name>         # state
#   journalctl -u forge-agent-<name> -f         # logs
#   sudo -u <runAs> tmux -L forge attach -t agent-<name>   # attach
#   sudo -u <runAs> tmux -L forge ls            # list all agents on this user
#
# The harness lives in a per-harness module (modules/harnesses/<harness>.nix)
# so swapping or adding harnesses (codex, custom processes) doesn't touch
# the agent schema or any other module.

let
  cfg = config.services.forge;

  claudeAgents =
    lib.filterAttrs (_: a: a.harness == "claude-code") cfg.agents;

  # Build CLAUDE.md as a build-time file so the role text doesn't have to
  # be embedded (and escaped) in the wrapper shell. The wrapper copies it
  # into the agent's state dir on every start (idempotent overwrite).
  mkClaudeMd = name: agent:
    pkgs.writeText "CLAUDE-${name}.md" ''
      # ${name}

      ${agent.role}
    '';

  mkWrapper = name: agent:
    let
      claudeMd = mkClaudeMd name agent;
      hasDiscord = agent.discordBot != null;
      tokenFile =
        if hasDiscord then cfg.discord.bots.${agent.discordBot}.tokenFile else "";
    in
    pkgs.writeShellApplication {
      name = "forge-agent-${name}";
      runtimeInputs = [ pkgs.tmux pkgs.jq pkgs.coreutils claudeCode ];
      text = ''
        set -euo pipefail

        STATE_DIR="$HOME/.local/state/forge/agents/${name}"
        mkdir -p "$STATE_DIR"

        # Refresh CLAUDE.md from the declared role on every start. Treat the
        # module-declared role as source of truth.
        cp -f "${claudeMd}" "$STATE_DIR/CLAUDE.md"

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
        exec tmux -L forge new-session -A -s "agent-${name}" \
          claude \
            --model "${agent.model}" \
            --effort max \
            --dangerously-skip-permissions \
            ${lib.optionalString hasDiscord
              ''--channels "plugin:discord@claude-plugins-official"''}
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

in
{
  config = lib.mkIf cfg.enable (lib.mkMerge [
    # Always install claude-code + tmux when forge is enabled, so operators
    # have them whether or not any agent is declared yet.
    {
      environment.systemPackages = [ claudeCode pkgs.tmux ];
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
