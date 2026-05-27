{
  description = "forge — metacraft agent system on NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    deploy-rs.url = "github:serokell/deploy-rs";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    claude-code.url = "github:sadjow/claude-code-nix";
  };

  outputs = { self, nixpkgs, deploy-rs, sops-nix, claude-code, ... }:
    let
      system = "x86_64-linux";

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
    };
}
