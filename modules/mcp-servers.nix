{ config, lib, ... }:

# MCP server library — declared once, referenced by name from agents.
#
# An MCP server is a local stdio process (Bun/Node/Python/binary) that
# claude-code launches via the `mcpServers` block of the per-agent
# .mcp.json file. Each declared server here corresponds to one entry in
# that JSON file when an agent whitelists it.
#
# These are NOT claude-code plugins (which have their own .claude-plugin/
# manifest and ship bundled MCP servers under ${CLAUDE_PLUGIN_ROOT}).
# v1's `--dangerously-load-development-channels server:<name>` mechanism
# maps to entries here in v2.
#
# This module declares the option family only. The harness reads
# `services.forge.mcpServers.<name>` for each name in an agent's
# `mcpServers` list and writes the entries into the per-agent .mcp.json.

{
  options.services.forge.mcpServers = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        command = lib.mkOption {
          type = lib.types.str;
          description = ''
            Executable that launches this MCP server. Resolved against
            the harness PATH at runtime — use absolute paths (e.g.
            "''${pkgs.bun}/bin/bun") for hermetic invocation.
          '';
          example = "bun";
        };

        args = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = ''
            Arguments passed to the command. Same shape as claude-code's
            native .mcp.json `args` field.
          '';
          example = lib.literalExpression ''[ "run" "/srv/forge/plugins/mercury/server.ts" ]'';
        };

        env = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          description = ''
            Extra environment variables passed to the MCP server process.
            Merged with the harness's own environment.
          '';
          example = lib.literalExpression ''{ MERCURY_DB = "/var/lib/mercury/mercury.db"; }'';
        };
      };
    });
    default = { };
    description = ''
      Forge MCP-server library. Each entry is a local MCP server that
      agents can opt into via their `mcpServers` field. Entries are
      transcribed into the per-agent .mcp.json on harness start.

      Names must be unique across the library — the harness asserts
      this at evaluation time.
    '';
    example = lib.literalExpression ''
      {
        mercury = {
          command = "bun";
          args = [ "run" "/srv/forge/plugins/mercury/server.ts" ];
          env = { MERCURY_DB = "/var/lib/mercury/mercury.db"; };
        };
      }
    '';
  };
}
