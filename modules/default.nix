{ config, lib, pkgs, ... }:

{
  options.services.forge = {
    enable = lib.mkEnableOption "forge agent system";
  };

  config = lib.mkIf config.services.forge.enable {
    # extension points added incrementally
  };
}
