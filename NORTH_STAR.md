# Forge — North Star

## The goal

Four humans, each good at different things — not rigid specialists; anyone can contribute to anything we're working on — building fast while keeping everything optimally engineered and well enough understood that we know it's directionally correct.

Speed alone is easy. The hard part is **speed with comprehension**. And comprehension isn't a tax on speed — it's what unlocks it. The more deeply we understand the system, the more we trust it, and the more autonomy we can grant.

**The endpoint:** we have a conversation in voice chat, MVPs and demos spin up, we move into real engineering, and humans no longer review every line of code — because we trust the substrate that produced it.

## The bootstrapping loop

> Understand deeply → trust → grant autonomy → go faster → repeat.

Forge is **iteration zero**. The single most important thing is that the system itself is well-built and understood. If we build this optimally engineered and fully understood, that's the proof the approach works — and the reward is more autonomy.

**The process is the product.**

## The framing shift

Stop building for specific deployments. Forge is a **composable Nix substrate** — a Nix module library where examples are different ways to configure an agent or a machine. We lean into flakes, latest features, and pure Nix idioms. Anything we'd reach for outside Nix (custom runtimes, JSON manifests, ad-hoc tools) is a smell; check whether Nix already solves it before adding a layer.

## Two gradients

Every machine and every agent sits somewhere on two orthogonal axes:

- **Trust gradient** — how sensitive is what this machine touches (keys, customer data, prod)
- **Autonomy gradient** — how much can it act without a human gate

Examples:
- Laptop = highest-trust / lowest-autonomy (human-gated)
- Burst worker = low-trust / high-autonomy
- Gateway = low-autonomy / high-exposure
- Sandbox = high-trust / no egress

These become Nix module parameters: permissions surface, gating policy, allowed substrates, egress rules. "What is this machine / agent allowed to do?" must have a checkable answer.

A third, derived property: **capability × cost** — which harness, model, thinking depth, context window. Correlates with the two gradients but is distinct. A burst worker gets a cheap config (many, ephemeral). A laptop agent gets premium (rare runs, high stakes).

## Machine archetypes

Examples of configurations, not fixed deployments. As we max out compute we add machines and specialize; the pipedream includes our own GPUs and dedicated private-compute boxes.

1. **Laptop** — each human's personal agent. Tight permissions, less autonomous, most powerful human↔agent interface. A sufficiently permissioned laptop can SSH out and use any other interface.
2. **Team server** — autonomous agent roles + shared infrastructure (turtle today).
3. **CI agents** — ephemeral, one-off, for reviews or CI fixes.
4. **Dedicated machines** — per-teammate hardware that still belongs to the team.
5. **Inference / GPU node** — local model hosting; no external token bottleneck, no off-prem sensitive context.
6. **Memory / knowledge node** — vector DB, Nostr-relay records, embeddings, indexing — the queryable substrate of the shared mind.
7. **Gateway / relay node** — Nostr relay, Discord bridge, SSH ingress. Small, stable, high-uptime — the front door.
8. **Burst workers** — generalization of CI. Pool for parallelizable work (refactors, evals, multi-agent exploration). First thing to rent compute for.
9. **Sandbox / private-compute** — isolated, no egress, for keys / secrets / customer data we don't want touching shared or external substrates.

## Specialists, not generalists

Not every agent should be the same. We build **specialists** — each agent with a narrow, well-scoped role — because a specialist's context can be crafted far more carefully than a generalist's. Smaller, focused context reasons better, retrieves memory better, costs less, and can be granted more autonomy within its scope. Specialization is what the trust × autonomy grid actually gets to leverage.

The price is coordination overhead: specialists have to communicate to do anything that spans their boundaries. That overhead is what the **substrate** is for — the interface lanes below, the structured channels, the agent-mediated and agent-to-agent comms. Without solid communication infrastructure, specialization just balkanizes the system. With it, specialization becomes the source of leverage.

This is why the communication layer is load-bearing — not an afterthought to the agent stack, but the thing that makes specialization viable in the first place.

## Interface lanes

Four distinct modes of information flow:

1. **Direct human ↔ human** (Discord, voice chat) — high-signal, low-volume. **This stays primary.** Agents observe and chime in only where useful.
2. **Agent ↔ agent** (verbose machine-speed substrate, likely the Nostr relay) — agents converse at machine speed without surfacing to humans.
3. **Agent → its human** (the shadow-and-distill flow) — each human has a personal agent that watches the team conversation, distills, raises signal, and helps turn thoughts into clear prompts/messages.
4. **Human ↔ agent ↔ agent ↔ human** (agent-mediated human-to-human) — agents act as conduits and translators between humans, not just observers. Enables time-shifting ("tell Bob when he's done with auth"), context-translation (Alice's question framed for Bob's current focus), async resolution (Bob's agent asks Alice's agent the obvious follow-up so Alice sees a resolved thread instead of being interrupted), cross-substrate routing (Alice in Discord → Bob's terminal).

**Hard constraint on lane 4:** every agent-mediated message has explicit **fidelity** (literal quote / distilled / paraphrase) and **provenance** ("from Alice via her agent, distilled from a Discord thread"). Without these, two humans feel like they communicated but their agents did and meaning drifted.

The trust gradient extends here: distinct from "do I trust my agent to act on my behalf in code," we now also need "do I trust my agent to represent me, and theirs to represent them."

## The shared mind

Not just shared memory — shared understanding, with five properties:

1. **Shared memory** — decisions, mistakes, and context persist and are retrievable. Nobody re-solves a solved problem or repeats a known mistake.
2. **Cross-pollination** — insight from one session (past or parallel) surfaces in another where it's relevant, even unprompted.
3. **Trustworthy introspection** — ask the system how something works, trust the answer. Documentation is alive and accurate, not aspirational. This is the "directionally correct" check made queryable.
4. **Comprehension as a first-class output** — the system produces understanding in the humans, not just working code. A correct PR nobody understands has partially failed.
5. **Bounded context** — the shared mind has membranes. Context flows where relevant but doesn't leak in and pollute unrelated conversations.

## Vocabulary

Dense terms that name the concept without a glossary. No precious or borrowed-from-niche words. Anyone on the team should walk into any file or channel and read it without a translation layer.

- **forge** — the system itself. Project name; no metaphor in descriptive text.
- **agent** — a persistent identity bound to a role, channel, memory, and permissions. Distinct from "session" (a single instance of running it).
- **session** — a single harness instance (claude-code, codex, …) running an agent.
- **create / start / stop / restart** — lifecycle. Create an agent once (set up identity); start / stop / restart its sessions.
- **procedure** — a named, repeated practice. **Playbook** — a curated set of procedures.
- **workspace** — a domain of work with its own state and members.
- **human** — the people on the team.
- **checkin** — the read-and-announce act at session start.
- **modules** — the Nix module library that defines all the building blocks.
- **config** (formal: **agentConfiguration**, mirroring `nixosConfiguration`) — the evaluated per-agent spec.

Historical vocabulary (keeper / hand / kindle / fold / unfold / refold / kata / hearth / alchemist / mise en place / ribosome / etc.) is retired. Existing memory and code keeps the old terms as historical record; new writing uses the new terms.

## Runtime model

Nix-native, flake-first, latest features. **No custom runtime tool.**

- **Nix is the assembler.** Modules → eval → per-agent config → wrapper script. `nix run <flake>#agent.auth` evaluates the config and spawns the harness with the right model, thinking depth, permissions, context window.
- **systemd supervises.** Each agent's lifecycle (start / stop / restart / auto-restart / logs) is a user service.
- **tmux attaches.** For sessions a human wants to read along with, tmux sits between the user and the systemd-managed process.
- **Cross-machine is also Nix.** A burst worker is `nix run <flake>#agent.scout` from wherever — the flake URL + attribute path IS the cross-machine reference. No JSON serialization, no ad-hoc protocol.

If we ever need cross-cutting operations (fleet-wide enumeration, attach-by-name, send-signal-by-name), they go into a thin `forge` CLI — built only when the pain shows up, not pre-emptively.

## The stack

```
modules                  (Nix module library — source)
  └─ Nix evaluation
       └─ config         (per-agent spec — agentConfiguration)
            └─ Nix assembles → systemd supervises → tmux attaches
                 └─ agent (running session)
```

## Multi-harness, multi-model

A config declares everything needed to spawn the right runtime:

- **harness** — `claude-code` | `codex` | future ones
- **model** — `opus-4.7` | `sonnet-4.6` | `haiku` | `gpt-5` | local / GPU-node models
- **thinking** — high / medium / low / none (translated per harness)
- **context window**, **tools**, **permissions**
- **cost class** — premium / balanced / cheap (declared expectation)

Optimization function: right config for the work. Heavy reasoning → Opus + deep thinking. Bulk edits → Sonnet, less thinking. Low-stakes routine → Haiku. High-volume private-context → local models on the GPU node. Codex slots in where its harness or RLHF tuning wins on a class of task (worth measuring, not assuming).

**Three picking-points** the design must support:

1. **Design-time** — predefined agent's config (auth role = opus + deep thinking; formatter role = haiku).
2. **Dispatch-time** — a coordinator picks who to delegate to ("need a TypeScript refactor; spin up a sonnet burst worker").
3. **Runtime** — escalation / fallback ("sonnet stuck → retry with opus"; "context window overflowing → archive + restart").

**Observability is load-bearing.** Cost-efficient + optimal output requires per-agent / per-session spend tracking. Without measurement, "optimal config" is a guess. Which configurations work for which work is institutional knowledge the shared mind has to hold.

**Harness portability.** Role definition probably needs a harness-agnostic core plus harness-specific tweaks — otherwise N copies of every role. Worth designing for from the start.

## Checks for any forge-substrate change

Before merging anything that touches forge itself:

- Does this make forge more composable, or more turtle-coupled?
- Where does this sit on trust × autonomy?
- What's the capability × cost choice, and is it tracked?
- Does it preserve comprehension (queryable, introspectable), or trade it for speed?
- Does it respect bounded context (membranes), or leak across?
- Does the naming pass the dense-not-precious test (no glossary needed)?
- Could Nix already do this, or are we adding a layer that competes with Nix?

## Bounded scope

What this doc deliberately doesn't decide (each gets its own design note when the pain arrives):

- Specific cross-machine dispatch protocol beyond `nix run <flake>#…`
- Specific memory store / vector DB implementation for the knowledge node
- Specific Nostr relay topology and identity model for inter-agent comms
- Personal-agent UI / UX (how a human sees their shadow agent)
- Migration plan from current turtle-monolithic forge to the composable structure
- Specific observability / cost-tracking stack
