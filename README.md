# PiPanda Dashboard

An auxiliary dashboard for a Bambu Lab P1S, running on a Raspberry Pi Zero 2 W.

The P1S is a good printer with a bad camera and a closed ecosystem. pipanda adds
the parts that are missing:

- a live camera feed from a Raspberry Pi camera module instead of the P1S's
  built-in 1080p/low-framerate stream
- recording for usable timelapse footage, driven by real layer-change events
  from the printer rather than by a timer
- a Home Assistant integration so the printer's chamber light and the room lights
  can be controlled together

## Status

Implemented so far: the backend that talks to the printer.

| Piece | State |
| --- | --- |
| Nix dev shell | done |
| Bambu cloud authentication (password, emailed code, authenticator app) | done, code path for authenticator app untested |
| Cloud MQTT status stream | done |
| LAN-mode MQTT status stream | done, needs `PIPANDA_PRINTER_HOST` |
| Chamber light / timelapse commands | done |
| Camera capture and WebRTC streaming | NixOS module done; hardware validation pending |
| Timelapse recording | not started |
| Home Assistant integration | not started |
| HTTP dashboard | not started |

## Getting started

```sh
nix develop
zig build
```

Then authenticate and watch the printer:

```sh
zig build run -- login          # prompts for email + password, handles 2FA
zig build run -- login --code   # for accounts with no password, only an emailed code
zig build run -- devices        # lists printers on the account
zig build run -- use <id>       # only needed if the account has several printers
zig build run -- watch          # live status, one line per update
zig build run -- watch --json   # the merged JSON status per update
zig build run -- light off      # chamber light
```

Add `--verbose` to any command to log protocol steps to stderr. Credentials are
redacted: the access token is never printed, the MQTT username appears as a
4-character prefix plus its length, and the LAN access code only as a length.
`watch --raw` dumps each report payload verbatim, which is the useful thing to
capture when the status model gets something wrong.

`login` stores an access token in `$PIPANDA_STATE_DIR` (the dev shell points this
at `./.state`), falling back to `$XDG_STATE_HOME/pipanda`. The file is written
`0600`. Bambu access tokens are bearer credentials valid for about three months
and the refresh endpoint has been dead for a while, so when one expires the fix
is to run `login` again.

### Cloud vs LAN

```sh
zig build run -- watch                                    # via us.mqtt.bambulab.com
PIPANDA_PRINTER_HOST=192.168.1.50 zig build run -- watch --lan   # direct to the printer
```

Both transports carry the same protocol. For a Pi sitting on the same network as
the printer, **LAN mode is the better default**: no internet dependency, no token
expiry, and lower latency. It needs "LAN Mode Liveview" enabled on the printer,
and it accepts the printer's self-signed certificate without verification —
which is unavoidable, because that certificate is not issued for the address you
dial. Cloud mode is fully verified against the system CA bundle.

### Cross-compiling for the Pi

```sh
zig build -Dtarget=aarch64-linux-gnu   -Dcpu=cortex_a53 -Doptimize=ReleaseSafe  # 64-bit Pi OS
zig build -Dtarget=arm-linux-gnueabihf -Dcpu=cortex_a53 -Doptimize=ReleaseSafe  # 32-bit Pi OS
```

No C dependencies, so this is a plain `zig build` with a target flag. Use
`musl` instead of `gnu`/`gnueabihf` for a fully static binary.

## Layout

```
src/
  main.zig              CLI
  root.zig              the `pipanda` module, for other consumers
  bambu/
    cloud.zig           HTTPS API: login, 2FA, device list
    credentials.zig     token store on disk
    printer.zig         live session: transport + status + commands
    status.zig          accumulated printer state
  net/
    mqtt.zig            minimal MQTT 3.1.1
    tls_stream.zig      TLS over TCP as a Reader/Writer pair
nix/
  modules/
    camera.nix          rpicam-vid hardware H.264 into go2rtc
    pi-zero-2-camera.nix  firmware camera detection and CMA setup
```

## Raspberry Pi camera

The camera pipeline is deliberately outside the Zig process:

```text
Camera Module 3 -> libcamera/rpicam-vid -> H.264 pipe -> go2rtc -> WebRTC browser
```

The Zero 2 W has a hardware H.264 encoder. `rpicam-vid` uses it through V4L2,
so the live path does not decode or transcode video and the Zig backend does not
copy video frames. go2rtc starts the capture process when the first viewer
arrives and stops it when the last viewer leaves.

Defaults:

- 1920x1080 at 30 fps
- H.264 baseline, 4 Mbit/s
- one-second keyframe interval with inline SPS/PPS
- continuous Camera Module 3 autofocus
- go2rtc API/demo page on TCP 1984
- WebRTC media on TCP and UDP 8555
- RTSP bound to localhost only

### Physical setup

Power the Pi completely off before connecting the camera. The Zero 2 W uses the
narrow 22-pin CSI connector; a normal Camera Module 3 uses a 15-pin connector,
so it needs the correct 15-to-22-pin camera cable. Do not use the visually
similar display cable.

### NixOS setup

The flake uses the active
[`nvmd/nixos-raspberrypi`](https://github.com/nvmd/nixos-raspberrypi)
framework for the vendor kernel, matching firmware, Raspberry Pi libcamera and
`rpicam-apps`. The older `nix-community/raspberry-pi-nix` project is archived.

`nixosConfigurations.pipanda-pi` evaluates a Pi Zero 2 W camera system. It is
intentionally not a complete install image yet: Wi-Fi credentials, an SSH key
and the deployment user must not be committed to this repository. The relevant
composition is:

```nix
modules = [
  nixos-raspberrypi.nixosModules.raspberry-pi-02.base
  self.nixosModules.pi-zero-2-camera
  self.nixosModules.pipanda-camera
  {
    services.pipanda-camera = {
      enable = true;
      rpicamPackage =
        nixos-raspberrypi.packages.aarch64-linux.rpicam-apps.override {
          withLibavEncoder = false;
          withDrmPreview = false;
          withEglPreview = false;
          withQtPreview = false;
          withOpenCVPostProc = false;
          withIMX500 = false;
        };
      openFirewall = true;

      # Set these if the camera is mounted upside down:
      # horizontalFlip = true;
      # verticalFlip = true;
    };
  }
];
```

The firmware uses `camera_auto_detect=1` to load the IMX708 and autofocus VCM
overlays. Do not add `dtoverlay=imx708` at the same time. The module reserves
128 MiB CMA for camera, ISP and encoder buffers, leaving the rest of the 512 MiB
for userspace.

### Validate on the Pi

After deploying and rebooting:

```sh
pipanda-camera-test
systemctl status go2rtc
journalctl -u go2rtc -f
```

`pipanda-camera-test` lists detected cameras, records three seconds through the
same hardware H.264 path used in production, verifies that the output is not
empty, and queries the local go2rtc API.

From another machine on the same LAN, open:

```text
http://<pi-address>:1984/stream.html?src=p1s&mode=webrtc
```

The first request starts `rpicam-vid`, so the initial image can take a moment.
Port 1984 has no authentication and exposes the go2rtc API; keep it on a trusted
LAN. Do not forward it directly to the internet. Remote access should eventually
go through the authenticated dashboard or Home Assistant.

### Why the status model is a JSON document

The P1 series does not resend its whole status object. `print.push_status`
carries only the fields that changed since the last report, so a consumer has to
maintain the accumulated document itself; only the X1 sends everything every
time.

Mirroring Bambu's ~150-field undocumented schema into Zig structs would mean
silently dropping anything added in a firmware update, so `status.zig` keeps the
state as a JSON object and deep-merges each report into it. Nested objects merge
key by key; arrays are replaced wholesale, because the printer resends a whole
array whenever any element changes. `Snapshot` provides typed access to the
fields the dashboard renders.

Merging replaces values without freeing the old ones, so the arena is rebuilt
every 512 merges to keep memory flat — this matters on a 512 MB Pi running for
weeks.

## Notes and caveats

- **Cloudflare.** The cloud API sits behind Cloudflare and rejects clients that
  do not look like the official network agent, so `cloud.zig` sends Orca Slicer's
  `User-Agent` and `X-BBL-*` headers. This works today, but it is a header
  allowlist and Bambu can tighten it at any time. There is no way to solve a JS
  challenge from a plain HTTP client; if that starts happening, `BlockedByCloudflare`
  is reported and LAN mode is the fallback.
- **`pushall` is expensive on a P1.** Bambu's own guidance is not to request the
  full status more than once every five minutes: the MCU is slow enough that
  serialising the whole document visibly stutters a print. pipanda sends it once
  at connect and then relies on deltas.
- **Authenticator-app login is untested.** The password and emailed-code paths
  were verified against the live API. The authenticator path posts to a different
  host and reads the token out of a `token` cookie; the code is there and follows
  the same flow the Home Assistant integration uses, but no account with an
  authenticator enrolled was available to test it.
- **Reconnection is not automatic yet.** `watch` exits when the connection drops.
  A supervisor loop belongs in the daemon, not the CLI.
- **`--lan` does not require LAN-Only mode on the printer.** It authenticates to
  the printer's local broker with the LAN access code, which leaves the cloud
  connection up and Bambu Handy working. Flipping the printer's own "LAN Only
  Mode" toggle is a separate, more drastic thing and is not needed here.

## Protocol references

The cloud API and MQTT protocol are undocumented and reverse engineered. Useful
prior art:

- [OpenBambuAPI](https://github.com/Doridian/OpenBambuAPI) — endpoint and MQTT
  topic documentation
- [ha-bambulab](https://github.com/greghesp/ha-bambulab) — the Home Assistant
  integration, and the source of the login state machine
