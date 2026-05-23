{
  description = "agicash team VPS — multi-user forge on AWS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    forge.url = "github:MakePrisms/forge";
  };

  outputs = { self, nixpkgs, forge, ... }: {
    # nixosConfigurations defined here once instance details are pinned
  };
}
