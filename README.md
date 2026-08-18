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
| Camera Module 3 capture and WebRTC streaming | Raspberry Pi OS module done; hardware validation pending |
| Timelapse recording | not started |
| Home Assistant integration | not started |
| HTTP dashboard | SolidJS device screen and Zig API implemented |
| Dashboard login | Settings page with Bambu Lab login (password, emailed code, authenticator) over the API |

## Getting started

```sh
nix develop
just build
```

Then authenticate and watch the printer:

```sh
just login              # prompts for email + password, handles 2FA
just login-code         # for accounts with no password, only an emailed code
just devices            # lists printers on the account
just run use <id>       # only needed if the account has several printers
just watch              # live status, one line per update
just watch --json       # the merged JSON status per update
just light off          # chamber light
just serve --lan        # frontend API on 127.0.0.1:8080
just web                # Vite frontend on 127.0.0.1:5173
```

Run `just` to list all development recipes. `just check` runs formatting,
type-checking and unit tests; `just ci` also validates the camera deployment,
cross-compiles for the Pi and evaluates the flake.

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
zig build -Dtarget=aarch64-linux-gnu   -Dcpu=baseline -Doptimize=ReleaseSafe  # 64-bit Pi OS
zig build -Dtarget=arm-linux-gnueabihf -Dcpu=baseline -Doptimize=ReleaseSafe  # 32-bit Pi OS
```

No C dependencies, so this is a plain `zig build` with a target flag. Use
`musl` instead of `gnu`/`gnueabihf` for a fully static binary.

## Layout

```
src/
  api.zig               frontend HTTP API and server
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
frontend/
  src/                  SolidJS dashboard and API client
  vite.config.ts        Vite server and Zig API proxy
  package.json          Bun-managed frontend dependencies
deploy/pi-os/
  install.sh            Raspberry Pi OS Lite installer
  pipanda-camera-source validated rpicam-vid hardware H.264 source
  pipanda-camera.service native systemd service
  go2rtc.yaml           WebRTC media sidecar configuration
```

## Raspberry Pi OS Lite deployment

The project targets a Pi Zero 2 W running 64-bit Raspberry Pi OS Lite. A manual
GitHub Action takes a version number and publishes a self-extracting ARM64
installer containing the static Zig backend, compiled frontend, go2rtc, camera
helpers, nginx configuration and systemd services. Zig, Bun, Node.js and Nix are
not required on the Pi.

### Prerequisites

- Raspberry Pi Zero 2 W running **64-bit** Raspberry Pi OS Lite
- Working network connection, DNS and system clock
- Wi-Fi and SSH configured
- Camera Module 3 connected with the correct 15-to-22-pin CSI cable, if camera
  support is wanted
- Internet access during installation so apt can install nginx and rpicam tools

The live path uses the Zero 2 W's hardware H.264 encoder and does not transcode:

```text
Camera Module 3 -> rpicam-vid -> go2rtc -> WebRTC
```

### Generate a release

1. Open this repository on GitHub and select **Actions**.
2. Select **Build Raspberry Pi installer**.
3. Select **Run workflow**.
4. Enter a semantic version such as `0.2.0` and start the workflow.
5. Download the `.run` installer and `.sha256` checksum from the resulting
   GitHub Release or workflow artifact.

The workflow also generates `pipanda-VERSION-CHANGELOG.md` from commits since
the previous version tag.

### Install on the Pi

Download a release directly on the Pi by replacing the version below:

```sh
VERSION=0.2.0
curl -fLO "https://github.com/aaryannemade/pipanda-dashboard/releases/download/v${VERSION}/pipanda-${VERSION}-aarch64.run"
curl -fLO "https://github.com/aaryannemade/pipanda-dashboard/releases/download/v${VERSION}/pipanda-${VERSION}-aarch64.run.sha256"
```

Verify and run it:

```sh
sha256sum --check "pipanda-${VERSION}-aarch64.run.sha256"
chmod +x "pipanda-${VERSION}-aarch64.run"
sudo "./pipanda-${VERSION}-aarch64.run"
```

The installer installs required Raspberry Pi OS packages, deploys all PiPanda
files, enables the services, and checks the frontend and backend before
reporting success.

Verify the installation:

```sh
systemctl status pipanda.service pipanda-camera.service nginx.service
curl http://127.0.0.1/api/v1/health
sudo pipanda-camera-test
```

Run the camera test with no browser stream open. Then visit
`http://<pi-address>/` or `http://<hostname>.local/`, open **Settings**, and sign
in to Bambu Lab. The default cloud transport does not require the printer's IP.

### Use LAN transport

Give the printer a stable DHCP lease and edit `/etc/pipanda/pipanda.env`:

```sh
PIPANDA_TRANSPORT=lan
PIPANDA_PRINTER_HOST=192.168.1.50
```

Apply the change:

```sh
sudo systemctl restart pipanda.service
```

Use `PIPANDA_TRANSPORT=cloud` to switch back. Configuration lives under
`/etc/pipanda`; credentials and the selected printer persist under
`/var/lib/pipanda`.

### Upgrade or uninstall

To upgrade, download a newer release and run its installer using the same
commands. Configuration and credentials are preserved.

To remove the installed services and application files:

```sh
sudo pipanda-uninstall
```

See [`deploy/pi-os/README.md`](deploy/pi-os/README.md) for release generation,
physical setup, cloud/LAN configuration, upgrades, security, diagnostics and
uninstall instructions.

## Dashboard API

Run the Zig HTTP backend. It starts even without credentials so login can happen
from the Settings page:

```sh
zig build run -- serve --lan
```

It exposes the live printer, job, controls, camera and AMS data needed by
the Bambu Handy-style device screen. See
[`docs/frontend-api.md`](docs/frontend-api.md) for the screenshot inventory,
endpoint contract, capability flags and examples.

## Frontend

The device screen is a responsive SolidJS application styled after Bambu Handy.
It polls the dashboard endpoint once per second, embeds the go2rtc WebRTC player,
renders live print and AMS state, and sends chamber-light commands.

Install the locked dependencies once:

```sh
just install
```

Run the API and Vite in separate terminals:

```sh
PIPANDA_PRINTER_HOST=192.168.1.50 just serve --lan
just web
```

Open `http://127.0.0.1:5173`. Vite proxies `/api` to the Zig server on port 8080.
Set `VITE_API_BASE` when building for a deployment where the API is on a
different origin. `just web-check` type-checks the app and `just web-build`
creates the production bundle in `frontend/dist`.

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
