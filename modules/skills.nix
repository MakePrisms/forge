{ config, lib, ... }:

# Skill library — declared once, referenced by name from agents.
#
# Each entry under `services.forge.skills.<name>` describes a claude-code
# skill: a directory containing a SKILL.md (and any supporting files)
# that the harness installs into the shared library at
# /etc/forge/skill-library/<name>/.
#
# Agents declare which skills they want via `services.forge.agents.<name>.skills`
# (defined in agents.nix). The harness then symlinks the agent's whitelist
# from the shared library into the agent's per-CWD `.claude/skills/` so the
# agent only sees its declared subset.
#
# This module declares the option family only. Installation (copy / symlink
# into /etc/forge/skill-library/) lives in modules/harnesses/claude-code.nix
# alongside the agent CWD assembly logic that consumes it.

{
  options.services.forge.skills = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
      options = {
        source = lib.mkOption {
          type = lib.types.path;
          description = ''
            Path to the skill's root directory — typically contains a
            SKILL.md plus any helper files. Installed (read-only) into
            /etc/forge/skill-library/<name>/ by the harness.
          '';
          example = lib.literalExpression "./skills/discord-tools";
        };

        description = lib.mkOption {
          type = lib.types.str;
          description = ''
            One-line description of what this skill does. Surfaced in
            the per-agent skill catalog (appended to the agent's system
            prompt) so the agent knows when to invoke it.
          '';
          example = "Discord channel/thread/pin ops via REST";
        };
      };
    }));
    default = { };
    description = ''
      Forge skill library. Each entry is a reusable claude-code skill
      that agents can opt into via their `skills` field.

      Names must be unique across the library — the harness asserts this
      at evaluation time.
    '';
    example = lib.literalExpression ''
      {
        discord-tools = {
          source = ./skills/discord-tools;
          description = "Discord channel/thread/pin ops via REST";
        };
      }
    '';
  };
}
