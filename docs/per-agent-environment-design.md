# Per-Agent Environment Design

Status: design spec for a follow-up implementation PR. Not code yet.

## Problem

Today every agent on a box shares one user-level claude-code environment: the same `~/.claude/skills/`, the same `~/.claude/plugins/`, the same MCP servers from `.mcp.json`. Per-agent customization in v1 happens at launch via `launch-agent --wallet --agicash --pikachat` flags that mix in extra MCP configs and development channels. Skills are user-global. Plugins are user-global.

That has three costs the north-star already says we want to pay differently:

- **Context pollution.** Every agent sees every skill description in its system prompt, every available plugin, regardless of whether it's relevant. NORTH_STAR.md's "bounded context" property is rhetorical until what an agent *can* see is bounded.
- **Trust gradient with no teeth.** `--dangerously-skip-permissions` everywhere; capability scoping is by convention, not by mechanism. The trust × autonomy grid axis is a label, not a substrate.
- **Reproducibility drift.** "What does this agent have access to?" depends on what was in `~/.claude/` at launch time. Answer is implicit and per-host.

This spec proposes declarative per-agent environments — each agent gets only the skills, MCP servers, plugins, and tool permissions it's been declared with. Nix assembles the env from a shared library; the harness exec's claude-code with explicit flags so nothing implicit leaks in.

## Goals

- **Declarative per-agent skill set.** `services.forge.agents.<name>.skills = [ "discord-tools" "verify" ]`.
- **Declarative per-agent MCP servers.** `services.forge.agents.<name>.mcpServers = [ "discord" "mercury" ]`.
- **Declarative per-agent plugins.** Same shape.
- **Declarative per-agent tool permissions.** `allowedTools` / `disallowedTools` shape from claude-code itself.
- **Shared library as the source of truth.** Skills, MCP servers, and plugins are declared once in modules; agents reference by name. One change to the shared definition, every agent that uses it picks it up on next deploy.
- **On-demand library access.** An agent that wasn't whitelisted for a skill can still reach into the shared library at `/etc/forge/skill-library/<name>` if it explicitly decides to — but the skill won't be auto-loaded or listed in its context until then. Default narrow, opt-in wide.
- **`nix develop .#agent.<name>` works.** Affordance for entering an agent's exact environment to debug or iterate.

## Non-goals (for this spec)

- No new abstractions beyond the existing module pattern. Skills / MCPs / plugins are new option families, but they live in the same submodule-merging style as `services.forge.discord.bots`.
- No memory / context-window management. That's gap #1 from the synthesis (bounded context implementation); separate spec.
- No federated skill library across machines. Single-host scope for now.
- No skill versioning / rollback. Same.
- No claude-code internals changes. Everything works via existing flags.

## Design

Three new option families plus an extension to `services.forge.agents.<name>`.

```nix
# The shared library — declared once, referenced many times.
services.forge.skills.discord-tools = {
  source = ./skills/discord-tools;
  description = "Discord channel/thread/pin ops via REST";
};

services.forge.mcpServers.mercury = {
  command = "${pkgs.mercury-mcp}/bin/server";
  env = { MERCURY_DB = "/var/lib/mercury/mercury.db"; };
  # ...full claude-code MCP config shape
};

services.forge.plugins.discord = {
  source = "${pkgs.claude-plugins-official}/discord";
  # or a flake input, or a fetched zip, etc.
};

# Per-agent whitelist (extending the existing agent schema via submodule
# merging — same pattern as discord.nix today).
services.forge.agents.coordinator = {
  role = "...";
  runAs = "gudnuf";
  discordBot = "team";
  skills = [ "discord-tools" "verify" ];
  mcpServers = [ "discord" "mercury" ];
  plugins = [ "discord" ];
  allowedTools = [ "Bash(git *)" "Edit" "Read" ];
};
```

### What the harness module does

For each agent declared with `harness = "claude-code"`, the existing `modules/harnesses/claude-code.nix` wrapper is extended to:

1. **Build a per-agent environment derivation.** Output structure under `$STATE_DIR/.claude/`:
   - `skills/<name>/` — symlinks to each declared skill's source
   - `mcp.json` — generated JSON listing only the declared MCP servers
   - `plugins/` — symlinks to each declared plugin's source
   - `settings.json` — claude-code settings (permission allowlist, etc.)
2. **Exec claude-code in `--bare` mode** with explicit flags pointing at the per-agent env:
   ```
   claude --bare \
     --add-dir "$STATE_DIR" \
     --mcp-config "$STATE_DIR/.claude/mcp.json" --strict-mcp-config \
     --plugin-dir "$STATE_DIR/.claude/plugins/discord" \
     --settings "$STATE_DIR/.claude/settings.json" \
     --allowedTools "..." \
     --model "${agent.model}"
   ```
   `--bare` skips user-level skill/plugin auto-discovery; `--strict-mcp-config` ensures only declared MCPs are loadable. The agent sees its declared skills and nothing else.
3. **Install the shared library at `/etc/forge/skill-library/`.** Every declared skill installs there regardless of which agents reference it. Agents can read from that path on demand if they need a skill they weren't whitelisted for (filesystem-level access, gated by Unix permissions on the runAs user).

### `nix develop .#agent.<name>`

The flake gains a `devShells.<system>.agent-<name>` output per agent. Entering it gives you a shell with:
- The same PATH the agent has (claude-code, tmux, jq, the wrappers)
- The same env vars (CLAUDE_CODE_*, DISCORD_STATE_DIR if applicable)
- The agent's `$STATE_DIR/.claude/` materialized in the shell's working dir

You can then run `claude` interactively in the exact same env the systemd service would, for iteration / debugging.

## Open questions

1. **Skill resolution under `--bare`.** Help text says `--bare` mode still resolves skills via `/skill-name` — but it doesn't say where it looks for them. Need to verify that skills placed in `--add-dir` paths are resolvable. If not, the fallback is symlink-farming into `~/.claude/skills/` per-agent, which requires each agent run as a distinct Linux user — workable but more ceremony.
2. **Plugin loading scope.** `--plugin-dir` is per-session and explicit. Does the plugin need its own per-agent state (analogous to `DISCORD_STATE_DIR`)? Probably yes for the discord plugin; less clear for others.
3. **Dev iteration.** When editing a skill, redeploying every agent that uses it is expensive. Mitigation: in a "dev mode" the skill source is bind-mounted from a path-input flake input rather than copied. Could be a flag on `services.forge.skills.<name>` like `dev = true`.
4. **Conflict resolution.** Two skills with overlapping `/slash-commands` — which wins? claude-code probably has a precedence rule; we should document it.
5. **Hot-reload.** Today an agent picks up a new skill on next `systemctl restart`. Acceptable for now; in the future, a `--reload` signal would be nice. Out of scope.
6. **MCP server lifecycle.** Per-agent stdio MCPs spawn one process per agent that uses them. For heavy MCPs (mercury, vector store), shared HTTP/SSE MCPs may make sense. Defer until pain shows up.
7. **Discoverability vs isolation.** If skills aren't auto-loaded, how does an agent discover what's available? Options: (a) an always-on "skill-catalog" skill that lists names + descriptions of everything in `/etc/forge/skill-library/`, (b) explicit `--append-system-prompt` listing what's whitelisted, (c) nothing — agents only use what's been declared for them. (c) is most disciplined; (a) is friendliest.

## Validation criteria

Before declaring done:

- `services.forge.agents.X.skills = [ "a" ]` results in skill `a` (and only `a`) being resolvable via `/a` in agent X's session.
- A skill not in the agent's whitelist is **not** listed in its system prompt or auto-loaded.
- `services.forge.agents.X.mcpServers = [ "discord" ]` results in `mcp__discord__*` tools being callable but `mcp__nwc__*` (if declared on the box) being unavailable.
- `nix develop .#agent.X` enters a shell where `claude` invocation matches the systemd unit's `ExecStart` exactly.
- A second agent on the same box, with a different whitelist, sees a different env. No state bleeds between them.

## Reference patterns informing this

- Existing `modules/discord.nix` shape (shared bot manifest + agent-side reference by name) — same pattern applied to skills / MCPs / plugins.
- claude-code's `--bare` + explicit flags model — designed for exactly this kind of programmatic invocation.
- NixOS pattern of "library modules declare; configuration declares which to use" — same shape as e.g. `services.nginx.virtualHosts` referenced by name.

## Implementation order (when this lands)

1. Add the three library options (`services.forge.skills`, `services.forge.mcpServers`, `services.forge.plugins`) — schema only, no behavior.
2. Extend `services.forge.agents.<name>` with the whitelist fields.
3. Update `modules/harnesses/claude-code.nix` to assemble the per-agent `$STATE_DIR/.claude/` and exec with `--bare` + explicit flags.
4. Add `devShells.<system>.agent-<name>` to the flake.
5. Migrate the demo agent declaration to use the new shape.
6. Verify the criteria above on the test instance.
