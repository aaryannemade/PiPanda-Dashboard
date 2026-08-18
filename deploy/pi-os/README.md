# Raspberry Pi OS Lite deployment

PiPanda targets a Raspberry Pi Zero 2 W running **64-bit Raspberry Pi OS
Lite**. The release installer contains the static ARM64 backend, compiled
SolidJS frontend, go2rtc, deployment scripts, systemd units and nginx site. The
Pi does not need Zig, Bun, Node.js, Nix or a repository checkout.

## Runtime layout

```text
Browser -> nginx :80
             |-- /          static SolidJS build
             |-- /api/      Zig API on 127.0.0.1:8080
             `-- /camera/   go2rtc signaling on 127.0.0.1:1984

pipanda.service        Bambu cloud/LAN MQTT and dashboard API
pipanda-camera.service go2rtc -> rpicam-vid -> Camera Module 3
```

WebRTC media travels directly between go2rtc and the browser on TCP/UDP 8555.
The camera is encoded by the Pi's H.264 hardware path and is not transcoded.

## Build a release

Open the repository's **Actions** tab, select **Build Raspberry Pi installer**,
choose **Run workflow**, and enter a semantic version such as `0.2.0`.

The manually triggered workflow:

1. Runs Zig, TypeScript, shell and deployment checks.
2. Builds the frontend with its locked Bun dependencies.
3. Cross-compiles a static `aarch64-linux-musl` backend for Cortex-A53.
4. Downloads go2rtc ARM64 and verifies its pinned SHA-256 digest.
5. Generates release notes from commits since the previous version tag.
6. Builds and stage-tests a self-extracting installer.
7. Produces the installer, checksum and changelog as a workflow artifact.
8. Creates or updates the matching `vVERSION` GitHub Release.

Release files:

```text
pipanda-0.2.0-aarch64.run
pipanda-0.2.0-aarch64.run.sha256
pipanda-0.2.0-CHANGELOG.md
```

The generated changelog is a release artifact and GitHub Release description;
the workflow does not create an automated commit on the source branch.

## Install

Prepare the latest 64-bit Raspberry Pi OS Lite, Wi-Fi and SSH. Copy the `.run`
file and checksum from the GitHub Release to the Pi, then run:

```sh
sha256sum --check pipanda-0.2.0-aarch64.run.sha256
chmod +x pipanda-0.2.0-aarch64.run
sudo ./pipanda-0.2.0-aarch64.run
```

The installer:

1. Rejects non-ARM64 systems.
2. Installs nginx, CA certificates, curl and `rpicam-apps-lite` (falling back to
   `rpicam-apps`) through apt.
3. Installs the backend, frontend, go2rtc, camera helpers and service units.
4. Preserves existing configuration and credentials during upgrades.
5. Enables and starts nginx, `pipanda.service` and
   `pipanda-camera.service`.
6. Checks the frontend and backend health endpoint before reporting success.

Open `http://<pi-address>/` or `http://<hostname>.local/`, select **Settings**,
and sign in to Bambu Lab. The backend starts without credentials, so no CLI
login is required before the dashboard opens.

## Configuration

Dashboard configuration is stored in `/etc/pipanda/pipanda.env`:

```sh
PIPANDA_HTTP_HOST=127.0.0.1
PIPANDA_HTTP_PORT=8080
PIPANDA_PRINTER_NAME=Panda
PIPANDA_PRINTER_MODEL=P1S
PIPANDA_CAMERA_URL="/camera/stream.html?src=p1s&mode=webrtc"
PIPANDA_TRANSPORT=cloud
```

Cloud transport needs no printer address. To use local MQTT, give the printer a
stable DHCP lease and configure:

```sh
PIPANDA_TRANSPORT=lan
PIPANDA_PRINTER_HOST=192.168.1.50
```

Then restart the backend:

```sh
sudo systemctl restart pipanda.service
```

Credentials and the selected printer are stored under `/var/lib/pipanda` by
systemd's `StateDirectory`. They are readable only by the dynamic service user
and persist across upgrades.

## Camera setup

Shut the Pi down before connecting the Camera Module 3 to the Zero 2 W's narrow
22-pin CSI connector. A standard module needs the correct 15-to-22-pin cable.
Current Raspberry Pi OS detects official cameras automatically; do not enable
the legacy camera stack or add `start_x=1`.

Defaults are 1920x1080 at 30 fps, H.264 baseline at 4 Mbit/s, one-second
keyframes and continuous autofocus. Tune `/etc/pipanda/camera.env`:

```sh
WIDTH=1920
HEIGHT=1080
FRAMERATE=30
BITRATE=4000000
AUTOFOCUS_MODE=continuous
HORIZONTAL_FLIP=0
VERTICAL_FLIP=0
```

Restart after editing:

```sh
sudo systemctl restart pipanda-camera.service
```

The hardware encoder path intentionally rejects dimensions above 1920x1080.

## Validate and diagnose

Run the camera hardware test with no browser stream open:

```sh
sudo pipanda-camera-test
```

Service status and logs:

```sh
systemctl status pipanda.service pipanda-camera.service nginx.service
journalctl -u pipanda.service -f
journalctl -u pipanda-camera.service -f
curl http://127.0.0.1/api/v1/health
rpicam-hello --list-cameras
```

Required LAN ports:

| Port | Protocol | Purpose |
| --- | --- | --- |
| 80 | TCP | Dashboard, API and camera signaling through nginx |
| 8555 | TCP/UDP | Direct WebRTC media |

go2rtc's API binds only to `127.0.0.1:1984`; nginx is the public signaling
entry point. The Zig backend also binds only to loopback. The dashboard still
does not implement user access control, so expose port 80 only on a trusted LAN
or place it behind an authenticated reverse proxy/VPN.

## Upgrade

Download and run a newer installer exactly as for the first installation. It
replaces versioned binaries, frontend assets and managed service configuration,
while preserving:

```text
/etc/pipanda/pipanda.env
/etc/pipanda/camera.env
/var/lib/pipanda/credentials.json
```

## Uninstall

```sh
sudo pipanda-uninstall
```

The uninstaller removes managed services, binaries, frontend assets and the
nginx site. Configuration and credentials are intentionally retained; it prints
the commands needed to delete those too.

## Development staging

The bundle installer supports a non-root staging mode used by CI:

```sh
./pipanda-VERSION-aarch64.run --extract /tmp/pipanda-bundle
bash /tmp/pipanda-bundle/install.sh --root /tmp/pipanda-root
```

The original `deploy/pi-os/install.sh` remains available for camera-only
development from a repository checkout. Normal users should use the release
installer.
