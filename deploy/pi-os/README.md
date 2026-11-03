# Raspberry Pi OS Lite deployment

PiPanda targets a Raspberry Pi Zero 2 W running **64-bit Raspberry Pi OS
Lite**. The release installer contains the static ARM64 backend, compiled
SolidJS frontend, go2rtc, deployment scripts, systemd units and nginx site. The
Pi does not need Zig, Bun, Nix or a repository checkout. Node.js 18+ is installed
for the on-demand signing-key refresh helper only; the dashboard backend itself
remains a standalone static binary.

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
3. Cross-compiles a static `aarch64-linux-musl` backend using the conservative
   AArch64 baseline required by the Pi Zero 2 W.
4. Downloads go2rtc ARM64 and verifies its pinned SHA-256 digest.
5. Rejects binaries containing optional ARM crypto instructions that cause
   `SIGILL` on this Pi.
6. Generates release notes from commits since the previous version tag.
7. Builds and stage-tests a self-extracting installer.
8. Produces the installer, checksum and changelog as a workflow artifact.
9. Creates or updates the matching `vVERSION` GitHub Release and marks it
   **Latest** after all assets have been uploaded.

Release files:

```text
pipanda-0.2.0-aarch64.run
pipanda-0.2.0-aarch64.run.sha256
pipanda-0.2.0-CHANGELOG.md
pipanda-latest-aarch64.run
pipanda-latest-aarch64.run.sha256
install.sh
```

The generated changelog is a release artifact and GitHub Release description;
the workflow does not create an automated commit on the source branch.
The `latest` installer is byte-identical to the versioned one, with its own
checksum file naming the alias. GitHub's Latest release designation supplies
the stable download URL; there is no moving `latest` Git tag. Running the
workflow again for an older version also promotes that release to Latest.

## Install

Prepare the latest 64-bit Raspberry Pi OS Lite, Wi-Fi and SSH. On the Pi, use
the following for both initial installation and upgrades, without entering a
version number:

```sh
curl -fsSL --proto '=https' --proto-redir '=https' https://github.com/aaryannemade/pipanda-dashboard/releases/latest/download/install.sh | bash
```

The bootstrap runs downloads as your normal user, checks the installer checksum,
then invokes sudo for installation. Temporary files are removed on success or
failure. If already root, it runs the verified installer directly. Do not pipe
into `sudo bash`; no privilege is needed for downloading. Requires curl, Bash
and sha256sum, included in Raspberry Pi OS Lite. It reuses the existing installer
and preserves its configuration/credential handling.

This executes a script supplied by this repository. HTTPS and the installer
checksum do not independently authenticate that bootstrap script. To review it
first, download `install.sh` using `curl -fLo install.sh` followed by the URL
above, inspect it, then run `bash install.sh`. Installer options can be passed
through, for example `bash install.sh --no-start`, or `| bash -s -- --no-start`
with the piped command.

Alternatively, download and verify the release manually:

```sh
curl -fLO https://github.com/aaryannemade/pipanda-dashboard/releases/latest/download/pipanda-latest-aarch64.run && \
curl -fLO https://github.com/aaryannemade/pipanda-dashboard/releases/latest/download/pipanda-latest-aarch64.run.sha256 && \
sha256sum --check pipanda-latest-aarch64.run.sha256 && \
sudo bash ./pipanda-latest-aarch64.run
```

The bootstrap and aliases are available starting with the first release from the updated
workflow. Downloads or checksum failures prevent installation. If a new release
appears between downloads, rerun the entire command to obtain a matching pair.
Versioned assets remain available for pinned installs or rollbacks.

The installer:

1. Rejects non-ARM64 systems.
2. Installs nginx, CA certificates, curl, Node.js and `rpicam-apps-lite` (falling
   back to `rpicam-apps`) through apt.
3. Installs the backend, frontend, go2rtc, camera helpers and service units.
4. Preserves existing configuration and credentials during upgrades.
5. Enables and starts nginx, `pipanda.service` and
   `pipanda-camera.service`.
6. Checks the frontend and backend health endpoint before reporting success.

Open `http://<pi-address>/` or `http://<hostname>.local/`, select **Settings**,
and sign in to Bambu Lab. The backend starts without credentials, so no CLI
login is required before the dashboard opens.

## Provision or refresh command-signing keys

After logging in through Settings, run on the Pi:

```sh
sudo pipanda-signing-refresh --restart
```

This command fetches and verifies current signing credentials, installs the
four files in `/var/lib/pipanda` with mode 0600 and the same owner as
`credentials.json`, then restarts **only** `pipanda.service`. It handles the
service's `DynamicUser` ownership automatically. It does not pause, stop, change
speed or start a print; restarting briefly disconnects the dashboard and
requests one full status report, so running between prints is preferable.
Network/provisioning failures preserve the previous keys and do not restart
the service. Concurrent refresh attempts are refused.

Omit `--restart` to replace the files without immediately reconnecting the
backend, then activate them later with `sudo systemctl restart pipanda.service`.
Use `--state-dir /absolute/path` for a custom state location. The helper uses
the saved Bambu login; an expired account token must be fixed by logging in
again in Settings. Key expiry is printed after refresh; no automatic timer is
installed.

### Add the helper to an existing installation

The next release installer includes it. To install just the helper now, copy
`deploy/pi-os/pipanda-signing-refresh` and `tools/signing-setup.mjs` from the
repository to your Pi, then run there (adjust the input paths):

```sh
sudo apt-get install --yes nodejs
sudo install -D -m 0755 pipanda-signing-refresh /usr/local/bin/pipanda-signing-refresh
sudo install -D -m 0644 signing-setup.mjs /usr/local/share/pipanda/signing-setup.mjs
sudo pipanda-signing-refresh --restart
```

This provisions keys only; an older backend still needs upgrading to the
version with signing support. A checkout on the Pi can instead run
`sudo bash deploy/pi-os/pipanda-signing-refresh --restart` directly.

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
ROI=0.108,0.108,0.892,0.892
HORIZONTAL_FLIP=0
VERTICAL_FLIP=0
```

Restart after editing:

```sh
sudo systemctl restart pipanda-camera.service
```

`ROI` crops at capture time and scales the selected region to the unchanged
1920x1080 output, without software video transcoding. Its four values are
`x,y,width,height`, fractions of the full sensor frame before flips. The
default retains the marked print area with a little extra left margin to
preserve 16:9 rather than stretching the image. Use `ROI=0,0,1,1` for the full
field of view; older configurations without `ROI` also remain uncropped.
Cropping keeps the output pixel dimensions, not the original field of view
or amount of image detail.

Installers preserve existing `camera.env` files. To apply this crop to an
existing Pi, update `/usr/local/libexec/pipanda-camera-source` from this release,
add the `ROI` line above to `/etc/pipanda/camera.env`, and restart the camera
service. The backend does not need restarting.

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
