# Agent runtime and interface design

## Problem statement

`modules/agents.nix` declares what an agent *is* — name, role, harness, model, runAs, optional Discord bot. It does not say how a session of that agent is launched, supervised, observed, attached, or stopped. Today on turtle (v1) that is the job of `launch-agent` and `tools/ribosome` — bash scripts that hardcode tmux, `claude --dangerously-skip-permissions`, sqlite-polled Mercury ack loops, and a baked-in agent registry. The substrate locks in claude-code and tmux at the lowest layer. v2 needs the inverse: a declarative agent layer with a runtime where harness, supervisor, and human-attach surface are independently swappable, and where launching on one machine versus another is the same operation.

## Goals and non-goals

**Goals.** Nix-native (declared config evaluates to a runnable thing without an out-of-band orchestrator). Harness-portable (claude-code today, codex or an in-house process tomorrow, same declaration). Supervised (start / stop / restart / auto-restart and log tail without a custom tool). Attachable (humans can read along). Observable (process state, logs, later per-session cost, queryable by name). Trust-aware (`runAs` is load-bearing; sessions inherit the user's permission surface, not the deploying admin's). Cross-machine symmetric (burst-worker on a remote box is the same shape as a long-lived agent on turtle).

**Non-goals (this pass).** A custom orchestrator binary — north star is explicit, build a `forge` CLI only when pain shows up. Locking in claude-code — nothing harness-specific in `modules/agents.nix`. Cross-cutting fleet ops (enumerate, attach-by-name across machines) — deferred until standard primitives feel insufficient. Vector-DB / memory backing, Nostr inter-agent comms, cost tracking — each is its own design note. Migration from turtle v1 — separate doc once the substrate is real.

## Survey of options

### 1. Lifecycle management

- **systemd user services.** One unit per agent, owned by `runAs`'s linger-enabled user. Native start / stop / restart, `Restart=on-failure`, `journalctl --user -u forge-agent-X`. Inherits the user's environment; respects `runAs` without elevation. Strong on declarative-ness, supervision, observability. Weakness: per-user lingering must be enabled.
- **systemd system services with `User=`.** Centralized via root `systemctl`, no linger. Loses the trust-isolation of a user-bus. Weakest fit for the trust gradient.
- **`nix run` directly.** No supervisor; the session is whatever shell ran it. Most Nix-native but no restart, no log retention. Fine for one-shot burst workers.
- **Containerized.** Strong isolation, resource bounding, clean teardown. Over-isolating for a coordinator whose job is touching the host repo. Right for sandbox later, wrong as default.
- **Custom supervisor.** Replicates ribosome in Rust or Go. North star explicitly warns against this.

### 2. Coordinator ↔ agent interaction

- **tmux attach.** Human-as-coordinator from v1. Read-along is excellent; scripting is brittle. Agents can't easily query a tmux pane.
- **MCP control plane.** Each agent exposes a small MCP server (`status`, `logs`, `signal`). Strong for future agent-mediated flows. Cost: every harness must expose it.
- **Custom CLI (`forge agent X status / logs / attach`).** Thin wrapper around journalctl + tmux + systemctl. Discoverable, scriptable, but pre-emptive — north star says build only when pain shows up.
- **Pure logs + signals.** journalctl for read, `systemctl kill -s` or a drop-file for write. No new abstraction. Weakest ergonomics, strongest portability, zero-debt.

### 3. Harness abstraction

- **Per-harness Nix module.** `modules/harnesses/claude-code.nix`, `modules/harnesses/codex.nix` etc., each contributing options under `services.forge.agents.<name>` (model alias mapping, thinking depth, flag wiring) and emitting a per-agent wrapper derivation. `agents.nix` stays harness-agnostic. Matches the submodule-merge pattern in `discord.nix`.
- **Single adapter shape (trait-like).** One module defines a contract (`{ command, env, args, attachable, signalProtocol }`) and each harness fills it in. Risk: the shape calcifies before we know what codex wants.
- **Wrapper script per harness.** Cheapest, hardest to introspect. Fine as the *body* of a harness module's derivation; wrong as the seam itself.
- **Embed harness logic in agents.nix.** Pre-empt this — the v1 mistake.

### 4. Launch primitive

- **`nix run .#agent.X`.** Most Nix-native; the flake URL + attr is the cross-machine reference. No supervision; fine for one-shot, weak for long-lived.
- **`systemctl --user start forge-agent-X`.** Boring, restartable, journaled. Cross-machine via SSH. Discoverable via `systemctl --user list-units 'forge-agent-*'`.
- **Both, layered.** The systemd unit's `ExecStart` *is* `nix run .#agent.X`. One artifact, two entry points: `nix run` for ephemeral, `systemctl` for managed.
- **`forge agent X start` CLI.** Defer.

### 5. What a good agent runtime gives you (ranked)

Ordered by what would hurt most to lose now:

1. **Declarative** — `nixos-rebuild` is the deploy path. Anything not derivable from the module is unsurfaced.
2. **Observable** — process state and log tail by name. Without this, supervision is theatre.
3. **Restartable** — single command, idempotent. Crash-recovery is auto-restart with backoff.
4. **Attachable** — human can read along when they want to.
5. **Transferable across machines** — same declaration runs on turtle, laptop, burst worker.
6. **Memory-persistent across restarts** — state dir survives unit restart; the agent does the actual persisting.
7. **Resource-bounded** — cgroups, memory ceiling. Important for burst workers, deferable for coordinators.
8. **Crash-recoverable** — narrowly, last-known-good. Replay / checkpoint is out of scope.

## Proposed direction

**Lifecycle: systemd user services, generated by Nix.** Each agent declaration emits one `systemd.user.services.forge-agent-${name}` unit owned by `runAs`. `Restart=on-failure`, `StandardOutput=journal`, `WorkingDirectory=` the agent's state dir. Linger enabled per declared user. Covers items 1–4 of the runtime criteria with no custom tool.

**Launch primitive: `nix run .#agent.${name}` is the canonical command, and it is exactly the systemd unit's `ExecStart`.** Long-lived sessions go through systemd; one-shot burst workers run `nix run` directly. Cross-machine is `ssh host -- nix run github:MakePrisms/forge#agent.scout` — no protocol to maintain.

**Harness abstraction: per-harness Nix modules, each contributing options to the agent submodule and producing the per-agent wrapper derivation.** `modules/agents.nix` stays harness-agnostic and validation-only; `modules/harnesses/claude-code.nix` owns the model-alias mapping, the `--dangerously-skip-permissions` decision, the plugin wiring. A new harness is a new file plus an enum entry. Same shape `modules/discord.nix` already uses.

**Coordinator ↔ agent: logs + signals first, tmux attach as the human escape hatch.** Read via `journalctl --user -u forge-agent-${name}`. Write via `systemctl --user kill -s SIGTERM` plus a drop-file convention under the agent's state dir for structured signals (e.g. "gather"). For human read-along the wrapper may run its session under `tmux new-session -d -s forge:${name}` so `tmux attach -t forge:${name}` works. No MCP control plane in this pass; revisit when agent-to-agent control becomes load-bearing.

**Explicitly punted, with triggers.**

- A `forge` CLI — when "find me the spinning agent on any machine" becomes a daily question.
- MCP control plane — when an agent legitimately needs to query another's state programmatically, not just consume Mercury / pikachat messages.
- Per-session cost tracking — separate observability module once the substrate is stable.
- Containerization — adopt for the sandbox archetype specifically; do not generalize.

Why this direction. It answers every numbered criterion with standard Linux primitives. The seam between declaration and runtime is the harness module — the seam the north star calls out as load-bearing for portability. The launch primitive is identical local and remote because the flake URL is the address. Each piece is independently revisitable: swap systemd without touching agent declarations; swap claude-code for codex without touching the supervisor; add MCP later as a sibling module without breaking the launch primitive.

## Open questions

1. **User-lingering policy.** Auto-enable `loginctl enable-linger` for declared forge users, or explicit opt-in? Silent-on = agents survive logout; explicit = clearer trust posture.
2. **State directory location.** `/var/lib/forge/agents/${name}/` vs `${HOME}/.local/share/forge/agents/${name}/`. User path agrees with `runAs`-bounded permissions; system path eases ops introspection.
3. **Default `Restart=`.** `on-failure` is conservative; `always` matches v1's instinct. Recommend `on-failure` with `StartLimitBurst` until we have cost-per-restart data.
4. **Flake attribute naming.** `.#agent.${name}` vs `.#agents.${name}` vs `.#forge-agent-${name}` — affects how the command reads.
5. **Identity for inter-agent comms.** v1 conflated Mercury identity with agent name. v2: inherit, or let the comms module own an identity option so agents can have separate Mercury / pikachat / Nostr identities without `name` overloaded?
6. **Tmux always-on or opt-in.** Default-on preserves attach affordance; default-off keeps the substrate headless.
7. **Multi-host agent registry.** When a burst worker on a rented box runs `nix run .#agent.scout`, does the deploying host know it exists? Answers whether registry / heartbeat is v2 or follow-up.

## Reference patterns surveyed

- **systemd + sd_notify + journalctl** — the boring answer, and the one that does most of the work for free.
- **Pure Nix flake apps (`nix run`)** — the cross-machine address space and the literal launch command.
- **Kubernetes operators** — control-loop and CRD-shaped declarations. Informed keeping declaration and runtime separate; pod / operator weight is wrong for this stage.
- **MCP control-plane pattern** — informed "logs + signals first, MCP later" sequencing.
- **deploy-rs** (agicash-mints) — Nix-native deploy semantics. Right shape for host configuration; wrong shape for per-agent process management.
- **Legacy `launch-agent` and `tools/ribosome` on turtle** — the pattern being abstracted away. Their accumulated complexity (sqlite-polled Mercury ack loops, kindle-prompt paste-into-tmux dance, in-bash agent registry, `--dangerously-skip-permissions` baked in) is the concrete cost of skipping a declarative layer; v2 keeps none of it and recovers most of the capability from standard primitives.
