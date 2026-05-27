# Per-Agent Environment Design

Status: design spec for a follow-up implementation PR. Not code yet.

## Problem

Today every agent on a box shares one workspace environment. v1's `launch-agent` script `cd`s into `/srv/forge` and exec's claude-code; claude-code then finds:

- `/srv/forge/.claude/skills/*` — nine skills, all visible to every agent (`board`, `discord-tools`, `gather`, `genesis`, `lanes-plan`, `lanes-status`, `meta-agent`, `session-lifecycle`, `tmux-lanes`)
- `/srv/forge/.mcp.json` — `nwc` and `playwright` MCP servers, always-on for every agent
- Plus extra MCP configs added per-launch via `--mcp-config` (`agicash.json`, `agicash-local.json`)
- Plus plugins loaded per-launch via `--channels plugin:discord@claude-plugins-official` and `--dangerously-load-development-channels server:mercury [server:nwc | server:pikachat | server:agicash[-local]]`

Per-agent customization happens at launch time via mutually-exclusive shell flags (`--wallet`, `--pikachat`, `--agicash`, `--agicash-local`) that *opt in* to extra channels and MCP configs. **Skills are not selectable at all** — every agent sees every project skill.

That has three costs the north-star already says we want to pay differently:

- **Context pollution.** Every agent sees every skill description in its system prompt regardless of relevance. NORTH_STAR.md's "bounded context" property is rhetorical until what an agent can see is bounded.
- **Trust gradient with no teeth.** `--dangerously-skip-permissions` is set for every agent in `launch-agent`. Capability scoping is by convention, not by mechanism. The trust × autonomy grid axis is a label, not a substrate.
- **Reproducibility drift.** "What does this agent have access to?" depends on what was in `/srv/forge/.claude/` at launch time + which shell flags fired. Answer is implicit and per-host.

This spec proposes **declarative per-agent environments** — each agent gets only the skills, MCP servers, plugins, and tool permissions it has been declared with. Nix assembles the env from a shared library; the harness `cd`s into a per-agent dir and exec's claude-code with explicit flags so nothing implicit leaks in.

## How v1 already does this (the seams we extend)

`launch-agent` already exhibits the structure we need, just for the wrong granularity:

1. **Per-agent state dir** — `/srv/forge/servers/default/agents/<identity>/` already exists, with `.env`, `access.json`, an `inbox/`. The harness writes per-agent files.
2. **CWD as the discovery root** — claude-code finds skills, `CLAUDE.md`, and `.mcp.json` from CWD. `launch-agent` cd's to `$FORGE_BASE` so all agents share the workspace's `.claude/`.
3. **`--mcp-config <path>`** is per-launch — that mechanism already isolates MCPs at launch time, just not declaratively.
4. **`--channels` / `--dangerously-load-development-channels`** are per-launch flags that load plugins for the session only.

v2's move: **change CWD to a per-agent dir**, populate that dir with exactly the declared skills + MCPs + plugins + CLAUDE.md, and exec claude-code with the existing flags pointing at the per-agent contents. The mechanism is already there; we just make it declarative and bound the contents.

## Goals

- **Declarative per-agent skill set.** `services.forge.agents.<name>.skills = [ "discord-tools" "verify" ]`.
- **Declarative per-agent MCP servers.** `services.forge.agents.<name>.mcpServers = [ "playwright" "agicash" ]`.
- **Declarative per-agent plugins.** Same shape. Loaded via `--plugin-dir` (the post-`--channels` path).
- **Declarative per-agent tool permissions.** `allowedTools` / `disallowedTools` from claude-code's existing flags.
- **Shared library as the source of truth.** Skills, MCP servers, and plugins declared once in modules; agents reference by name. One change at the library, every agent that uses it picks it up on next deploy.
- **On-demand library access.** A skill the agent wasn't whitelisted for is still readable at `/etc/forge/skill-library/<name>` — the agent can pull it explicitly if it decides to. Default narrow, opt-in wide. (Same pattern for plugins and MCPs.)
- **`nix develop .#agent.<name>` works.** Free affordance for entering the agent's exact environment.

## Non-goals (for this spec)

- No new abstractions beyond the existing module pattern. Skills / MCPs / plugins are new option families but live in the same submodule-merging style as `services.forge.discord.bots`.
- No memory / context-window management (that's the broader bounded-context gap from the synthesis; separate spec).
- No federated skill library across machines. Single-host scope.
- No skill versioning / rollback.
- **No claude-code internals changes.** Everything works via existing flags v1 already uses.

## Design

Three new library option families plus an extension to `services.forge.agents.<name>`.

```nix
# Library — declared once, referenced many times.

services.forge.skills.discord-tools = {
  source = ./skills/discord-tools;
  description = "Discord channel/thread/pin ops via REST";
};

services.forge.mcpServers.playwright = {
  command = "npx";
  args = [ "@playwright/mcp@latest" "--headless" ];
  # ... full claude-code MCP config shape
};

services.forge.plugins.discord = {
  # source can be a path, a flake input, or a fetched marketplace plugin
  source = "${pkgs.claude-plugins-official}/discord";
};

services.forge.plugins.mercury = {
  source = ../forge/plugins/mercury;  # the v1 Bun/TS plugin
};

# Per-agent whitelist — extends the existing schema via submodule merging
# (same pattern as discord.nix today).

services.forge.agents.coordinator = {
  role = "...";
  runAs = "gudnuf";
  discordBot = "team";
  skills = [ "discord-tools" "verify" ];
  mcpServers = [ "playwright" ];
  plugins = [ "discord" "mercury" ];
  allowedTools = [ "Bash(git *)" "Edit" "Read" ];
};
```

## What the harness module does

For each agent declared with `harness = "claude-code"`, `modules/harnesses/claude-code.nix`'s wrapper script (from PR #11) extends to:

1. **Install the shared library at `/etc/forge/`.** Skills go to `/etc/forge/skill-library/<name>/`; plugins go to `/etc/forge/plugin-library/<name>/`. Done once at activation, regardless of which agents reference what.

2. **Build the per-agent CWD on startup.** `$STATE_DIR/<name>/` becomes:
   - `CLAUDE.md` — already written from the declared role (PR #11)
   - `.claude/skills/<skill>` — symlinks into `/etc/forge/skill-library/<skill>` for each declared skill
   - `.claude/settings.json` — claude-code settings (permission allowlist, model defaults, etc.)
   - `.mcp.json` — generated JSON listing **only** declared MCP servers
   - `.env` — already written for `DISCORD_BOT_TOKEN` if discord is wired (PR #11)

3. **Exec claude-code with explicit flags from per-agent dir.** Inside the tmux session:

   ```bash
   cd "$STATE_DIR/$NAME"
   exec claude \
     --model "${agent.model}" \
     --strict-mcp-config \
     --mcp-config .mcp.json \
     ${each_plugin_as: --plugin-dir /etc/forge/plugin-library/<name>} \
     --allowedTools "${joined agent.allowedTools}" \
     --settings .claude/settings.json \
     --dangerously-skip-permissions
   ```

   Per-agent CWD gives natural project-level discovery of `CLAUDE.md` + `.claude/skills/`. `--strict-mcp-config` ensures no MCPs leak in from `/srv/forge/.mcp.json` or anywhere else. `--plugin-dir` for each declared plugin gives explicit per-session plugin loading (replaces v1's `--channels` / `--dangerously-load-development-channels` mechanism with a more declarative path). `--allowedTools` and `--settings` give the trust gradient teeth.

   No `--bare` — CLAUDE.md auto-discovery in CWD is exactly what we want once CWD is controlled.

## `nix develop .#agent.<name>`

The flake gains a `devShells.<system>.agent-<name>` output per agent. Entering it gives a shell with:

- Same PATH (claude-code, tmux, jq, the wrappers)
- Same env vars (CLAUDE_CODE_*, DISCORD_STATE_DIR if applicable)
- The agent's `$STATE_DIR/<name>/` materialized in the shell's working dir
- A printed `claude …` command exactly matching the systemd unit's ExecStart

You can then run `claude` interactively in the exact same env the service would, for iteration or debugging.

## Open questions

1. **`--plugin-dir` vs v1's `--channels` for the existing Discord plugin.** v1 uses `--channels plugin:discord@claude-plugins-official` for the production discord plugin. The cleaner mechanism is `--plugin-dir /etc/forge/plugin-library/discord` pointing at the same source. Need to verify: can we ship the official discord plugin's source through Nix (flake input, fetched zip, or pkg), and does `--plugin-dir` load it identically?
2. **Plugin per-agent state.** The discord plugin needs `DISCORD_STATE_DIR` set; other plugins may have similar conventions. Each plugin module probably needs to declare an `env` or `runtimeSetup` hook the wrapper invokes.
3. **Dev iteration.** Editing a skill shouldn't require redeploying every agent that uses it. Mitigation: `services.forge.skills.<name>.dev = true` causes the symlink to point at a flake `path:` input rather than a copy.
4. **Conflict resolution.** Two skills with overlapping `/slash-commands` — what's the precedence? Document claude-code's rule; surface as eval-time warning if two whitelisted skills collide.
5. **Hot-reload.** Today a new skill needs `systemctl restart` to take effect (the symlink farm is built on startup). Acceptable for now; a `--reload` signal would be nice later.
6. **MCP server lifecycle.** Per-agent stdio MCPs spawn one process per agent that uses them. For heavy MCPs (mercury, vector store), shared HTTP/SSE MCPs may make sense. Defer until pain shows up.
7. **Discoverability vs isolation.** If skills aren't auto-loaded for every agent, how does an agent discover what's available in the shared library? Options: (a) an always-on `skill-catalog` skill that lists names + descriptions of everything in `/etc/forge/skill-library/`, (b) explicit `--append-system-prompt` listing what's whitelisted, (c) nothing — agents only use what's been declared. (c) is most disciplined; (a) is friendliest for human-driven personal-coordinator use.

## Validation criteria

Before declaring done:

- `services.forge.agents.X.skills = [ "discord-tools" ]` results in only `discord-tools` being resolvable via `/discord-tools` in agent X's session. The other eight skills are not listed and not invokable.
- A skill not in agent X's whitelist is **not** listed in its system prompt.
- `services.forge.agents.X.mcpServers = [ "playwright" ]` results in `mcp__playwright__*` tools being available but `mcp__nwc__*` being unavailable, **even though `/srv/forge/.mcp.json` exists on the box**.
- `nix develop .#agent.X` enters a shell where `claude` invocation matches the systemd unit's `ExecStart` exactly.
- Two agents on the same box, different whitelists, see different envs. No state bleeds.
- The discord plugin still works as it does in v1 — agent joins Discord, responds to `@mentions` — but loaded via `--plugin-dir`, not `--channels`.

## Reference patterns informing this

- Existing `modules/discord.nix` shape (shared manifest + agent-side reference by name) — same pattern applied three times for skills, MCPs, plugins.
- v1 `launch-agent`'s per-agent state dir + per-launch flag mechanism — already two-thirds of the design; v2 just makes it declarative and CWD-bound.
- claude-code's `--strict-mcp-config + --plugin-dir + --add-dir + --settings + --allowedTools` set — designed for exactly this programmatic per-session invocation.
- NixOS pattern of "library modules declare; configuration declares which to use" — `services.nginx.virtualHosts` shape.

## Implementation order (when this lands)

1. Add three library option families (`services.forge.skills`, `services.forge.mcpServers`, `services.forge.plugins`) — schema only.
2. Add the shared library installation in the harness module — populates `/etc/forge/skill-library/` and `/etc/forge/plugin-library/` from declared library entries.
3. Extend `services.forge.agents.<name>` with the four whitelist fields.
4. Update `modules/harnesses/claude-code.nix` to build per-agent CWD contents + exec with the explicit flag set above.
5. Add `devShells.<system>.agent-<name>` flake output.
6. Migrate the demo agent declaration to use the new shape.
7. Verify each criterion in the Validation section on the test instance.
