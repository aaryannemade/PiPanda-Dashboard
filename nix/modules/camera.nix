{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.pipanda-camera;

  boolArg = enabled: flag: lib.optional enabled flag;

  captureArgs = [
    "--timeout"
    "0"
    "--nopreview"
    "--codec"
    "h264"
    "--inline"
    "--profile"
    "baseline"
    "--level"
    "4.1"
    "--width"
    (toString cfg.width)
    "--height"
    (toString cfg.height)
    "--framerate"
    (toString cfg.framerate)
    "--bitrate"
    (toString cfg.bitrate)
    "--intra"
    (toString cfg.framerate)
    "--autofocus-mode"
    cfg.autofocusMode
    "--output"
    "-"
  ]
  ++ boolArg cfg.horizontalFlip "--hflip"
  ++ boolArg cfg.verticalFlip "--vflip"
  ++ cfg.extraArgs;

  rpicamVid = lib.getExe' cfg.rpicamPackage "rpicam-vid";
  source = "exec:${rpicamVid} ${lib.escapeShellArgs captureArgs}#killsignal=2#killtimeout=5";

  # The NixOS go2rtc module points at a full FFmpeg package by default. This
  # pipeline feeds H.264 directly from rpicam-vid, so retaining FFmpeg would add
  # a large, unused closure to a small SD card. Keep a clear failure mode if a
  # future stream accidentally asks go2rtc to transcode.
  noFfmpeg = pkgs.writeShellScriptBin "ffmpeg" ''
    echo "FFmpeg is intentionally absent: pipanda-camera is a no-transcode pipeline" >&2
    exit 1
  '';

  cameraTest = pkgs.writeShellApplication {
    name = "pipanda-camera-test";
    runtimeInputs = [
      cfg.rpicamPackage
      pkgs.coreutils
      pkgs.curl
    ];
    text = ''
      set -eu

      echo "Detected cameras:"
      rpicam-hello --list-cameras

      output="$(mktemp --suffix=.h264)"
      trap 'rm -f "$output"' EXIT

      echo
      echo "Capturing three seconds with the production encoder settings..."
      rpicam-vid \
        --timeout 3000 \
        --nopreview \
        --codec h264 \
        --inline \
        --profile baseline \
        --level 4.1 \
        --width ${toString cfg.width} \
        --height ${toString cfg.height} \
        --framerate ${toString cfg.framerate} \
        --bitrate ${toString cfg.bitrate} \
        --autofocus-mode ${lib.escapeShellArg cfg.autofocusMode} \
        ${lib.optionalString cfg.horizontalFlip "--hflip"} \
        ${lib.optionalString cfg.verticalFlip "--vflip"} \
        --output "$output"

      bytes="$(stat --format=%s "$output")"
      if [ "$bytes" -eq 0 ]; then
        echo "Capture failed: encoder produced an empty file" >&2
        exit 1
      fi

      echo "Capture OK: $bytes bytes"
      echo
      echo "go2rtc API:"
      curl --fail --silent --show-error \
        "http://127.0.0.1:${toString cfg.apiPort}/api/streams" || {
          echo >&2
          echo "go2rtc is not reachable; inspect: journalctl -u go2rtc" >&2
          exit 1
        }
      echo
    '';
  };
in
{
  options.services.pipanda-camera = {
    enable = lib.mkEnableOption "PiPanda Camera Module 3 WebRTC feed";

    rpicamPackage = lib.mkOption {
      type = lib.types.package;
      description = ''
        Raspberry Pi's rpicam-apps package. Set this to the rpicam-apps package
        exported by nvmd/nixos-raspberrypi; stock nixpkgs does not provide the
        Raspberry Pi camera applications.
      '';
    };

    streamName = lib.mkOption {
      type = lib.types.str;
      default = "p1s";
      description = "go2rtc stream name.";
    };

    width = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1920;
      description = "Encoded video width.";
    };

    height = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1080;
      description = "Encoded video height.";
    };

    framerate = lib.mkOption {
      type = lib.types.ints.between 1 60;
      default = 30;
      description = "Frames per second. Also used as the keyframe interval.";
    };

    bitrate = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4000000;
      description = "H.264 bitrate in bits per second.";
    };

    autofocusMode = lib.mkOption {
      type = lib.types.enum [
        "auto"
        "continuous"
        "manual"
      ];
      default = "continuous";
      description = "Camera Module 3 autofocus mode.";
    };

    horizontalFlip = lib.mkEnableOption "horizontal camera image flip";
    verticalFlip = lib.mkEnableOption "vertical camera image flip";

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "--denoise"
        "cdn_off"
      ];
      description = "Additional arguments passed to rpicam-vid.";
    };

    apiAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Address for the go2rtc HTTP API and WebRTC demo page.";
    };

    apiPort = lib.mkOption {
      type = lib.types.port;
      default = 1984;
      description = "go2rtc HTTP API port.";
    };

    webrtcPort = lib.mkOption {
      type = lib.types.port;
      default = 8555;
      description = "WebRTC TCP and UDP media port.";
    };

    openFirewall = lib.mkEnableOption "the go2rtc API and WebRTC ports";
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.width <= 1920 && cfg.height <= 1080;
        message = ''
          The Pi Zero 2 W hardware H.264 encoder is supported here up to
          1920x1080. Higher Camera Module 3 sensor modes need another pipeline.
        '';
      }
    ];

    services.go2rtc = {
      enable = true;
      settings = {
        api.listen = "${cfg.apiAddress}:${toString cfg.apiPort}";
        ffmpeg.bin = lib.getExe noFfmpeg;
        rtsp.listen = "127.0.0.1:8554";
        webrtc.listen = ":${toString cfg.webrtcPort}";
        streams = {
          "${cfg.streamName}" = source;
        };
      };
    };

    # The source is demand-driven: go2rtc starts rpicam-vid when the first
    # viewer arrives and sends SIGINT when the last one leaves.
    systemd.services.go2rtc = {
      serviceConfig = {
        Restart = "on-failure";
        RestartSec = "2s";
      };
      environment.LIBCAMERA_LOG_LEVELS = "*:WARN";
    };

    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts = [
        cfg.apiPort
        cfg.webrtcPort
      ];
      allowedUDPPorts = [ cfg.webrtcPort ];
    };

    environment.systemPackages = [ cameraTest ];
  };
}
