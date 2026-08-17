# Raspberry Pi OS Lite camera module

This module targets a Raspberry Pi Zero 2 W running **64-bit Raspberry Pi OS
Lite** with a Camera Module 3. Nix is only used on the development workstation;
the Pi uses native Debian packages, systemd and files under `/usr/local`.

## Pipeline

```text
Camera Module 3
  -> rpicam-vid (hardware H.264)
  -> stdout pipe
  -> go2rtc
  -> WebRTC browser / Home Assistant
```

go2rtc starts `rpicam-vid` when the first viewer connects and stops it when the
last viewer leaves. It fans one camera capture out to multiple consumers, so a
future dashboard, Home Assistant and recorder do not compete for the camera.

Defaults:

- 1920x1080 at 30 fps
- H.264 baseline at 4 Mbit/s
- one-second keyframe interval with inline SPS/PPS
- continuous Camera Module 3 autofocus
- HTTP API and test viewer on TCP 1984
- WebRTC media on TCP/UDP 8555
- RTSP on localhost:8554 for future recording

There is no decode or transcode in the live path.

## Physical setup

1. Shut the Pi down and remove power.
2. Connect the Camera Module 3 to the Zero 2 W's narrow 22-pin CSI connector.
   A normal Camera Module 3 needs the correct 15-to-22-pin camera cable.
3. Confirm the contacts face the correct direction before closing both latches.
4. Boot the latest 64-bit Raspberry Pi OS Lite and complete Wi-Fi/SSH setup.

Official cameras are detected automatically by current Raspberry Pi firmware.
Do not enable the legacy camera stack or add `start_x=1`.

## Install

On the Pi, from the repository checkout:

```sh
cd pipanda-dashboard
sudo ./deploy/pi-os/install.sh
```

The installer:

1. Installs `rpicam-apps-lite` (or `rpicam-apps` on older releases), curl and CA
   certificates with apt.
2. Downloads go2rtc v1.9.14 for the detected ARM architecture.
3. Verifies the binary against its SHA-256 digest published by GitHub Releases.
4. Installs the source wrapper, configuration and systemd unit.
5. Enables and starts `pipanda-camera.service`.

Re-running the installer upgrades managed files but preserves
`/etc/pipanda/camera.env`.

## Validate

Close any open stream and run:

```sh
sudo pipanda-camera-test
```

The diagnostic stops the service temporarily, lists detected cameras, captures
four seconds through the exact production wrapper, verifies non-empty H.264,
restarts go2rtc, and checks its local API.

Then open this from another device on the same LAN:

```text
http://<pi-address>:1984/stream.html?src=p1s&mode=webrtc
```

The first connection starts the camera, so the image can take a moment to
appear.

Useful diagnostics:

```sh
systemctl status pipanda-camera.service
journalctl -u pipanda-camera.service -f
rpicam-hello --list-cameras
```

## Tune

Edit `/etc/pipanda/camera.env`:

```sh
sudoedit /etc/pipanda/camera.env
sudo systemctl restart pipanda-camera.service
```

Available settings:

```text
WIDTH=1920
HEIGHT=1080
FRAMERATE=30
BITRATE=4000000
AUTOFOCUS_MODE=continuous  # auto, continuous, manual
HORIZONTAL_FLIP=0          # 0 or 1
VERTICAL_FLIP=0            # 0 or 1
```

The wrapper rejects dimensions above 1920x1080 for this hardware encoder path.
Set both flips to `1` if the module is mounted upside down.

## Service layout

```text
/etc/pipanda/camera.env
/etc/pipanda/go2rtc.yaml
/etc/systemd/system/pipanda-camera.service
/usr/local/bin/go2rtc
/usr/local/bin/pipanda-camera-test
/usr/local/libexec/pipanda-camera-source
```

The service uses a transient systemd user with access to the `video` and
`render` groups. It has no login shell, no permanent credentials and no access
to home directories.

## Dashboard integration

Port 1984 is unauthenticated and is exposed only to make initial testing easy.
When the Zig dashboard implements its authenticated WebRTC signaling proxy,
change `/etc/pipanda/go2rtc.yaml` to:

```yaml
api:
  listen: "127.0.0.1:1984"
```

The browser will send its SDP offer to Zig. Zig will forward it to go2rtc's
local WHEP endpoint, while encrypted media continues directly between the
browser and go2rtc on port 8555. Never forward port 1984 directly to the
internet.

## Uninstall

```sh
sudo ./deploy/pi-os/uninstall.sh
```

Local configuration under `/etc/pipanda` is preserved intentionally.
