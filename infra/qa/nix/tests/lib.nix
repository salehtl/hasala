# Shared by the infra checks: a minimal x86_64-linux NixOS system with
# services.hasala on, evaluated (never built) from this flake's own nixpkgs.
{ self, nixpkgs }:
rec {
  # The tunnel id the golden config is rendered for (spec 05 §7.4 step 1).
  testTunnelId = "00000000-0000-4000-8000-000000000000";

  base = {
    nixpkgs.hostPlatform = "x86_64-linux";
    boot.loader.grub.enable = false;
    fileSystems."/" = {
      device = "/dev/vda";
      fsType = "ext4";
    };
    system.stateVersion = "26.05";
    services.hasala.enable = true;
  };

  evalSystem =
    extra:
    nixpkgs.lib.nixosSystem {
      modules = [
        self.nixosModules.hasala
        base
        extra
      ];
    };
}
