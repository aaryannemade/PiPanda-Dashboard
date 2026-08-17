{
  description = "pipanda — auxiliary dashboard for a Bambu Lab P1S, hosted on a Raspberry Pi Zero 2 W";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Vendor kernel, firmware, libcamera and rpicam-apps. The older
    # nix-community/raspberry-pi-nix project is archived; this is its active
    # successor.
    nixos-raspberrypi = {
      url = "github:nvmd/nixos-raspberrypi/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-raspberrypi,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      nixosModules = {
        pipanda-camera = import ./nix/modules/camera.nix;
        pi-zero-2-camera = import ./nix/modules/pi-zero-2-camera.nix;
      };

      # A camera-capable Pi Zero 2 W system closure. Network credentials,
      # users/SSH keys and the pipanda daemon itself stay in the host-specific
      # deployment module; this host is useful now for evaluation and for
      # deploying the camera module onto an existing NixOS Pi.
      nixosConfigurations.pipanda-pi = nixos-raspberrypi.lib.nixosSystem {
        inherit nixpkgs;
        modules = [
          nixos-raspberrypi.nixosModules.raspberry-pi-02.base
          self.nixosModules.pi-zero-2-camera
          self.nixosModules.pipanda-camera
          {
            networking.hostName = "pipanda";
            fileSystems."/" = {
              device = "/dev/disk/by-label/NIXOS_SD";
              fsType = "ext4";
            };
            services.pipanda-camera = {
              enable = true;
              rpicamPackage = nixos-raspberrypi.packages.aarch64-linux.rpicam-apps.override {
                withLibavEncoder = false;
                withDrmPreview = false;
                withEglPreview = false;
                withQtPreview = false;
                withOpenCVPostProc = false;
                withIMX500 = false;
              };
              openFirewall = true;
            };
            system.stateVersion = "26.05";
          }
        ];
      };

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          name = "pipanda-dev";

          packages = [
            # backend toolchain
            pkgs.zig
            pkgs.zls

            # protocol poking: talk to the printer / cloud by hand
            pkgs.mosquitto # mosquitto_sub, mosquitto_pub
            pkgs.curl
            pkgs.jq
            pkgs.openssl # s_client for inspecting the printer's TLS cert

            # phase 2: camera capture + timelapse assembly
            pkgs.ffmpeg-headless

            # deployment to the pi
            pkgs.rsync
            pkgs.openssh
          ];

          shellHook = ''
            # keep zig's global cache inside the repo so the shell is self-contained
            export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global"

            # secrets and tokens live here, gitignored
            export PIPANDA_STATE_DIR="$PWD/.state"
            mkdir -p "$PIPANDA_STATE_DIR"

            echo "pipanda dev shell — zig $(zig version)"
            echo "  zig build run -- login          authenticate with the bambu cloud"
            echo "  zig build run -- watch          stream printer status"
            echo "  cross-compile: zig build -Dtarget=aarch64-linux-musl -Dcpu=cortex_a53"
          '';
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
