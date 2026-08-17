{
  description = "pipanda — auxiliary dashboard for a Bambu Lab P1S, hosted on a Raspberry Pi Zero 2 W";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
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
