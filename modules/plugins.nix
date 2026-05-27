{ config, lib, ... }:

# Plugin library — declared once, referenced by name from agents.
#
# A claude-code plugin is a directory containing a .claude-plugin/plugin.json
# manifest (and typically bundled commands, agents, hooks, MCP servers, etc.).
# The harness loads declared plugins via `--plugin-dir <path>`; claude-code
# resolves ${CLAUDE_PLUGIN_ROOT} inside the plugin's bundled .mcp.json
# automatically when loaded this way.
#
# v1's `--channels plugin:<name>@<marketplace>` mechanism (claude-plugins-official
# marketplace) maps to entries here in v2. Local plugins authored alongside
# forge live the same way — anything with a .claude-plugin/plugin.json works.
#
# This module declares the option family only. The harness copies each
# declared plugin into /etc/forge/plugin-library/<name>/ and emits a
# `--plugin-dir /etc/forge/plugin-library/<name>` flag per agent-whitelisted
# plugin.

{
  options.services.forge.plugins = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        source = lib.mkOption {
          type = lib.types.path;
          description = ''
            Path to the plugin's root directory — the directory that
            contains `.claude-plugin/plugin.json`. Installed (read-only)
            into /etc/forge/plugin-library/<name>/ by the harness.
          '';
          example = lib.literalExpression "./plugins/discord";
        };
      };
    });
    default = { };
    description = ''
      Forge plugin library. Each entry is a claude-code plugin (with a
      `.claude-plugin/plugin.json` manifest) that agents can opt into
      via their `plugins` field.

      Names must be unique across the library — the harness asserts
      this at evaluation time.
    '';
    example = lib.literalExpression ''
      {
        discord = {
          source = ./plugins/discord;
        };
      }
    '';
  };
}
