{
  description = "forge — metacraft agent system on NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    deploy-rs.url = "github:serokell/deploy-rs";
    deploy-rs.inputs.nixpkgs.follows = "nixpkgs";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    claude-code.url = "github:sadjow/claude-code-nix";
  };

  outputs = { self, nixpkgs, deploy-rs, sops-nix, claude-code, ... }:
    let
      system = "x86_64-linux";

      # The deployed NixOS system is linux-only, but operators run the
      # deploy tooling from whichever machine they're on. Expose devShells
      # for the common operator platforms so `nix develop` works there.
      devShellSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forEachDevSystem = f:
        nixpkgs.lib.genAttrs devShellSystems
          (s: f (import nixpkgs { system = s; }) s);

      # Authorized SSH pubkeys — single source of truth shared with the
      # terraform layer (which reads the same file for aws_key_pair). Both
      # sides consume `deployments/agicash-team-forge/authorized-keys`,
      # one OpenSSH pubkey per line, `#` for comments. Drift impossible
      # by construction.
      agicashTeamForgeKeys =
        let
          raw = nixpkgs.lib.fileContents ./deployments/agicash-team-forge/authorized-keys;
          lines = nixpkgs.lib.splitString "\n" raw;
        in
        nixpkgs.lib.filter
          (l: l != "" && !(nixpkgs.lib.hasPrefix "#" l))
          lines;
    in
    {
      # Reusable NixOS module — composed by any deployment under deployments/.
      nixosModules.default = ./modules/default.nix;

      # ---------------------------------------------------------------------
      # agicash-team-forge: first concrete deployment.
      # ---------------------------------------------------------------------
      nixosConfigurations.agicash-team-forge = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          "${nixpkgs}/nixos/modules/virtualisation/amazon-image.nix"
          sops-nix.nixosModules.sops
          self.nixosModules.default
          ./deployments/agicash-team-forge/configuration.nix
        ];
        specialArgs = {
          sshPublicKeys = agicashTeamForgeKeys;
          claudeCode = claude-code.packages.${system}.default;
        };
      };

      deploy.nodes.agicash-team-forge = {
        # Placeholder — the real hostname is injected at deploy time via
        # `--hostname` by the `nix run .#deploy` app, which reads it from
        # `tofu output -raw public_ip`. Direct `deploy .#agicash-team-forge`
        # without `--hostname` is intentionally broken so operators are
        # routed through the wrapper (single source of truth = tf state).
        hostname = "use-nix-run-deploy-not-direct";
        sshUser = "root";
        profiles.system = {
          user = "root";
          # Build on the target machine. The EC2 box has the disk + Nix store;
          # operator laptops don't need a Linux builder.
          remoteBuild = true;
          path = deploy-rs.lib.${system}.activate.nixos
            self.nixosConfigurations.agicash-team-forge;
        };
      };

      # Only generate deploy checks for systems where deploy-rs.lib exists.
      checks = builtins.mapAttrs
        (system: lib: lib.deployChecks self.deploy)
        deploy-rs.lib;

      # Per-operator devShell. `nix develop` puts the full deploy toolchain
      # on PATH at versions pinned to this flake's inputs, so two operators
      # don't drift on tool versions and a fresh checkout never asks "how
      # do I install terraform / sops / age / …".
      devShells = forEachDevSystem (pkgs: sys: {
        default = pkgs.mkShell {
          packages = [
            pkgs.opentofu                      # `tofu` — free, drop-in for terraform
            pkgs.awscli2                       # `aws`
            pkgs.sops                          # secrets editor; sops-nix workflow
            pkgs.age                           # `age` / `age-keygen` — sops backend
            pkgs.jq                            # used by misc scripts and the harness
            deploy-rs.packages.${sys}.default  # `deploy` — nix-side deploy
          ];
        };
      });

      # `nix run .#deploy` — the single deploy entry point.
      #
      # Reads the box's current public IP from `tofu output -raw public_ip`
      # at invocation time and passes it to deploy-rs as `--hostname`, so
      # there is never a deploy-config.nix file to forget to update or to
      # disagree with terraform state. Extra args pass through to deploy-rs
      # (e.g. `nix run .#deploy -- --skip-checks`).
      apps = forEachDevSystem (pkgs: sys:
        let
          script = pkgs.writeShellApplication {
            name = "forge-deploy";
            runtimeInputs = [
              pkgs.opentofu
              pkgs.git
              deploy-rs.packages.${sys}.default
            ];
            text = ''
              set -euo pipefail
              repo=$(git rev-parse --show-toplevel)
              cd "$repo"
              ip=$(tofu -chdir=deployments/agicash-team-forge/terraform output -raw public_ip 2>/dev/null || true)
              if [ -z "$ip" ]; then
                echo "✗ no terraform output 'public_ip' available." >&2
                echo "  Provision the box first:" >&2
                echo "    cd deployments/agicash-team-forge/terraform && tofu apply" >&2
                exit 1
              fi
              echo "→ deploying to $ip" >&2
              exec deploy --hostname "$ip" "$@" .#agicash-team-forge
            '';
          };
        in
        {
          deploy = {
            type = "app";
            program = "${script}/bin/forge-deploy";
          };
        });
    };
}
