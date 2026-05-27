# Per-Agent Environment Design

Status: design spec for a follow-up implementation PR. Reviewed by adversarial passes (technical/flag + design/substrate); revised against findings.

## Problem

Today every agent on a box shares one workspace environment. v1's `launch-agent` cd's into `/srv/forge` and exec's claude-code; claude-code then finds:

- `/srv/forge/.claude/skills/*` — nine project-level skills, all visible to every agent
- `/srv/forge/.mcp.json` — `nwc` and `playwright` MCP servers, always-on for every agent
- Plus per-launch additions via `--mcp-config`, `--channels`, `--dangerously-load-development-channels`
- Plus **binary-bundled skills** (`verify`, `run`, `loop`, `init`, `code-review`, `security-review`, `update-config`, `keybindings-help`, `claude-api`, ~12 more) that load unconditionally
- Plus **user-level state**: `~/.claude/projects/<encoded-cwd>/memory/MEMORY.md` auto-loads per CWD, `~/.claude/settings.json` + `settings.local.json` merge into permission allowlists
- Plus user-installed plugins from `~/.claude/plugins/`

Per-agent customization happens at launch via shell flags (`--wallet`, `--pikachat`, `--agicash`); **skills are not selectable at all**. Agents see every project skill, every binary-bundled skill, every user plugin, every user setting. Bounded context is rhetorical.

Three costs the north-star says we want to pay differently:

- **Context pollution.** Every agent's system prompt lists everything available. NORTH_STAR's "bounded context" property is undeliverable until what an agent sees is bounded.
- **Trust gradient with no teeth.** `--dangerously-skip-permissions` is set for every agent. Capability scoping is by convention. **Per gudnuf's call: keep `--dangerously-skip-permissions` as the default for now — scoped-down agents are a separate design problem requiring real thought about what each role actually needs.** The spec ships the schema seam for scoping; the actual policy comes from a follow-up.
- **Reproducibility drift.** "What does this agent have access to?" depends on what was in `/srv/forge/.claude/` + which shell flags fired + what's in `~/.claude/`. Answer is implicit and per-host.

## How v1 already does this (the seams we extend)

`launch-agent` already exhibits the structure we need, just for the wrong granularity:

1. **Per-agent state dir** — `/srv/forge/servers/default/agents/<identity>/` already exists with `.env`, `access.json`, `inbox/`.
2. **CWD as a discovery root** — claude-code finds project-level `CLAUDE.md`, `.claude/skills/`, and `.mcp.json` from CWD.
3. **`--mcp-config <path>`** is already per-launch, just not declarative.
4. **`--channels` / `--dangerously-load-development-channels`** are per-launch plugin loaders (undocumented in current `claude --help` but still functional).

v2's move: **change CWD to a per-agent dir**, populate that dir with exactly the declared content, exec claude-code in `--bare` mode with explicit add-back flags so nothing implicit leaks in.

## The exec recipe (verified against claude-code 2.1.150)

```bash
cd "$STATE_DIR/$NAME"
exec claude \
  --bare \
  --add-dir "$STATE_DIR/$NAME" \
  --model "${agent.model}" \
  --mcp-config .mcp.json \
  ${each_plugin_as:} --plugin-dir /etc/forge/plugin-library/<name> \
  --settings .claude/settings.json \
  --setting-sources project \
  --append-system-prompt-file .claude/skill-catalog.md \
  --dangerously-skip-permissions \
  --allowedTools "${joined agent.allowedTools}"
```

Why each flag:

- **`--bare`** blocks all implicit context: binary-bundled skills, auto-`MEMORY.md`, user settings, user plugins, hooks, attribution, keychain reads, CLAUDE.md auto-discovery. The only way to actually achieve bounded context.
- **`--add-dir "$STATE_DIR/$NAME"`** restores `CLAUDE.md` discovery for the per-agent dir (since `--bare` disables CLAUDE.md auto-discovery).
- **`--mcp-config .mcp.json`** loads only the agent's declared MCPs from the per-agent CWD. **No `--strict-mcp-config`** — strict silently strips plugin-bundled MCP servers (`${CLAUDE_PLUGIN_ROOT}/mcp.json`), which would break discord, mercury, pikachat, nwc. With `--bare` already gating user-level MCPs, strict is redundant and harmful.
- **`--plugin-dir`** per declared plugin. Each plugin's bundled `.mcp.json` loads via the plugin path (tool prefix becomes `mcp__plugin_<name>_<server>__`).
- **`--settings .claude/settings.json`** + **`--setting-sources project`** loads only the per-agent settings file; without `--setting-sources project`, user `settings.json`/`settings.local.json` merge in.
- **`--append-system-prompt-file .claude/skill-catalog.md`** injects a generated skill catalog (name + description per declared skill) so the agent knows what's available without us loading every skill body into context. Skills remain invocable via `/skill-name` from CWD's `.claude/skills/`. This resolves the "discoverability vs isolation" open question (Worker B #8) — narrow context with discoverable invocation.
- **`--dangerously-skip-permissions`** stays per gudnuf's call. Scoped-down agents will need their own design pass.
- **`--allowedTools`** explicit even with skip-permissions because it controls which tools the model knows it has (affects system prompt and tool-call grammar), independent of permission gating.

## Per-agent CWD contents (built by harness on every start)

```
$STATE_DIR/$NAME/
  CLAUDE.md                          # role text (written from declared role)
  .mcp.json                          # generated; lists only declared MCPs
  .claude/
    settings.json                    # generated; permission allow/deny, model defaults
    skill-catalog.md                 # generated; appended to system prompt
    skills/
      <skill>/ → /etc/forge/skill-library/<skill>   # symlink per declared skill
  .env                               # bot tokens, etc. — already from PR #11 for discord
```

## Goals

- **Declarative per-agent skill set.** `skills = [ "discord-tools" "verify" ]` — only those are invocable and visible in the catalog.
- **Declarative per-agent MCP servers.** `mcpServers = [ "playwright" ]` — only those load.
- **Declarative per-agent plugins.** `plugins = [ "discord" "mercury" ]` — each becomes a `--plugin-dir`.
- **Declarative per-agent tool permissions.** Schema-only for now; `allowedTools` populates `--allowedTools`; `permissions.skipPrompts` defaults `true`.
- **Shared library as source of truth.** Skills/plugins/MCPs declared once, referenced by name.
- **On-demand library access.** The agent can `Read` from `/etc/forge/skill-library/<other>` if it chooses; symlinks only contain the whitelist.
- **`nix develop .#agent.<name>`** prints the exact exec recipe for the agent.

## Non-goals (for this spec)

- **Scoped-down permissions** — defer. `--dangerously-skip-permissions` stays default. `permissions` schema exists; policy comes later.
- **Per-agent Linux user** (Worker B's biggest miss) — defer. Current design has agents on same `runAs` user → trust isolation not OS-enforced. The follow-up that introduces `forge-agent-<name>` Linux users is named here as a known gap.
- **Plugin/comms split** (Worker B) — defer. For the demo, `services.forge.plugins.<name>` covers both marketplace plugins (discord) and dev-channel plugins (mercury). When Mercury identity/state wiring matters, split into `services.forge.comms.<name>`.
- **Hooks** (Worker B) — defer. PreToolUse/PostToolUse hooks are arguably more load-bearing for trust gradient than `allowedTools`; they get their own module family later.
- **Library namespacing** — defer. Single-host single-team for now; eval-time assertion catches duplicate `services.forge.skills.<name>` definitions.
- **Memory/context-window management** — separate spec (the broader bounded-context gap from the synthesis).
- **Federation across machines** — separate concern.

## Design

Three new library option families plus an extension to `services.forge.agents.<name>`.

```nix
# Library — declared once, referenced many times.

services.forge.skills.discord-tools = {
  source = ./skills/discord-tools;   # path; activation copies into /etc/forge/skill-library/discord-tools
  description = "Discord channel/thread/pin ops via REST";
};

services.forge.mcpServers.playwright = {
  command = "npx";
  args = [ "@playwright/mcp@latest" "--headless" ];
  env = { ... };
};

services.forge.plugins.discord = {
  source = "${pkgs.claude-plugins-official}/discord";  # path to plugin dir containing .claude-plugin/plugin.json
};

services.forge.plugins.mercury = {
  source = ../forge/plugins/mercury;  # v1's Bun/TS plugin
};

# Per-agent whitelist — extends the existing schema via submodule merging.

services.forge.agents.coordinator = {
  role = "...";
  runAs = "gudnuf";
  discordBot = "team";

  skills      = [ "discord-tools" "verify" ];
  mcpServers  = [ "playwright" ];
  plugins     = [ "discord" "mercury" ];
  allowedTools = [ "Bash(git *)" "Edit" "Read" "mcp__plugin_discord_discord__reply" ];

  permissions = {
    skipPrompts = true;   # default; flip for scoped agents (future)
    # allow = [...]; deny = [...]; — populated when scoping policy lands
  };
};
```

**Library entry source type discipline:** `source` is always a Nix path (or string that resolves to a path). The harness activation copies (or symlinks) it into `/etc/forge/{skill,plugin}-library/<name>/`. No mixed types.

## What the harness module does

For each agent with `harness = "claude-code"`, the wrapper script (from PR #11) extends to:

1. **Install the shared library at `/etc/forge/`** during activation:
   - `services.forge.skills.<name>` → `/etc/forge/skill-library/<name>/`
   - `services.forge.plugins.<name>` → `/etc/forge/plugin-library/<name>/`
   - Eval-time assertion: each name unique across the library.

2. **Build per-agent CWD on each start** (`$STATE_DIR/$NAME/`):
   - `CLAUDE.md` from role (idempotent)
   - `.claude/skills/<name>` symlinks for each declared skill
   - `.claude/settings.json` generated from `permissions.{allow,deny}` and any other agent-level settings
   - `.claude/skill-catalog.md` generated — `# Available skills\n\n- /<skill>: <description>` per declared skill
   - `.mcp.json` generated — only declared MCP servers
   - `.env` (existing PR #11 plumbing for discord bot token)

3. **Exec claude-code with the recipe above.**

4. **Expose `nix develop .#agent.<name>`** — entering prints the exact systemd ExecStart command and leaves you in `$STATE_DIR/$NAME` with the right env, ready to run `claude` interactively.

## Validation criteria

Before declaring done:

- **Skill isolation.** Agent X declared `skills = [ "discord-tools" ]`. Verify: only `discord-tools` resolvable via `/discord-tools`. Binary-bundled skills (verify, run, etc.) **not** in system prompt. The other declared library skills not in catalog.
- **MCP isolation.** Agent X declared `mcpServers = [ "playwright" ]`. Verify: `mcp__playwright__*` tools available; `mcp__nwc__*` from `/srv/forge/.mcp.json` **not** available; user-level MCPs **not** available.
- **Plugin MCPs load.** Agent X declared `plugins = [ "discord" ]`. Verify: `mcp__plugin_discord_discord__*` tools available (plugin's bundled MCP loaded via `--plugin-dir`, not stripped).
- **MEMORY.md doesn't leak.** No `~/.claude/projects/.../memory/MEMORY.md` written/read for `$STATE_DIR/$NAME` runs.
- **User settings don't leak.** A `~/.claude/settings.local.json` with `permissions.allow = ["Bash(*)"]` does **not** affect agent X (whose settings.json says otherwise).
- **Two agents, different whitelists, no bleed.** Same-host, same-user. (OS-level isolation tracked separately under the per-agent-user follow-up.)
- **`nix develop .#agent.<name>`** prints the same exec command the systemd unit runs.

## Other corrections from technical review

- **`--mcp-config <file>`** errors if the file doesn't exist. Harness must always write the file (even empty `{"mcpServers": {}}`).
- **`--plugin-dir`** must point at the directory containing `.claude-plugin/plugin.json` (the plugin's root, not a parent or child).
- **`${CLAUDE_PLUGIN_ROOT}` substitution** in plugin-bundled `.mcp.json` works automatically when loading via `--plugin-dir` (no manual resolution needed).
- **`--tools ""`** strips built-in tool surface (Bash/Edit/Read/etc.) entirely; reserve for future non-coding-agent roles. Not in default recipe.
- **`-p`/print mode silently ignores invalid settings files;** validation criteria run interactive (the agent's actual mode).

## Reference patterns informing this

- v1 `launch-agent`'s per-agent state dir + per-launch flag mechanism — already two-thirds of the design.
- claude-code 2.1.150's `--bare` + explicit-flag-set — designed for exactly this programmatic per-session invocation.
- `services.forge.discord.bots` submodule-merging pattern — three new option families follow the same shape.
- NixOS pattern of "library modules declare; configuration declares which to use" (e.g., `services.nginx.virtualHosts`).

## Implementation order (when this lands)

For the demo, ship in this order. Each step independently testable.

1. **Library schemas.** Add `services.forge.{skills,mcpServers,plugins}` option families. No behavior.
2. **Library installation.** Harness module activation copies/symlinks declared library entries to `/etc/forge/{skill,plugin}-library/<name>/`. Eval-time uniqueness assertions.
3. **Agent-side whitelist fields + `permissions` submodule.** Schema-only; `permissions.skipPrompts` defaults `true`.
4. **CWD assembly + exec recipe.** Harness wrapper builds `$STATE_DIR/$NAME/{CLAUDE.md, .mcp.json, .claude/...}` on every start; exec recipe per spec.
5. **Skill catalog generation.** `.claude/skill-catalog.md` from declared skills' descriptions; `--append-system-prompt-file` flag wired.
6. **Migrate demo agent.** Update `deployments/agicash-team-forge/configuration.nix` example to use new shape.
7. **`nix develop .#agent.<name>`** devShell output (lowest priority; cosmetic affordance).
8. **Run validation criteria** on test instance.

**Trimmed demo minimum (if time-bound):** steps 1, 2, 3, 4, 6. Skip 5 (catalog) and 7 (devShell). Validation reduces to skill+MCP isolation only.
