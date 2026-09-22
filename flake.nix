{
  description = "sernix — server configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nur.url     = "github:nix-community/NUR";
  };

  outputs = { self, nixpkgs, nur }:
  let
    cfg = import ./config.nix;

    mkHost = { hostname, system ? "x86_64-linux" }:
      nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          flake        = self;
          nur          = nur;
          hostname     = hostname;
          powerProfile = cfg.powerProfile;
          gpu          = cfg.gpu;
          cpuVendor    = cfg.cpuVendor;
          nvidiaBusId  = cfg.nvidiaBusId;
          amdBusId     = cfg.amdBusId;
          intelBusId   = cfg.intelBusId;
        };
        modules = [
          ./hardware-configuration.nix
          ./base.nix
        ];
      };

  in {
    nixosConfigurations = {
      ${cfg.hostname} = mkHost {
        inherit (cfg) hostname;
      };
    };
  };
}
