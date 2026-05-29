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

      # Per-operator deploy seam (gitignored — copy from deploy-config.nix.example).
      # Holds the EC2 public IP (from `terraform output -raw public_ip`) and the
      # SSH public keys authorized on the box. Each operator keeps their own copy.
      agicashTeamForgeConfig =
        import ./deployments/agicash-team-forge/deploy-config.nix;
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
          inherit (agicashTeamForgeConfig) sshPublicKeys;
          claudeCode = claude-code.packages.${system}.default;
        };
      };

      deploy.nodes.agicash-team-forge = {
        hostname = agicashTeamForgeConfig.hostname;
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
    };
}
