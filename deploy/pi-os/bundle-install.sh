#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$SCRIPT_DIR/payload"
ROOT="${DESTDIR:-}"
START_SERVICES=1
INSTALL_PACKAGES=1

usage() {
  cat <<'EOF'
Usage: sudo ./pipanda-VERSION-aarch64.run [options]

Install or upgrade PiPanda on 64-bit Raspberry Pi OS Lite.

Options:
  --root PATH       stage files below PATH instead of installing on this host
  --no-start        install files without enabling or starting services
  --no-packages     do not install Raspberry Pi OS packages with apt
  -h, --help        show this help
EOF
}

while (($#)); do
  case "$1" in
    --root)
      [[ $# -ge 2 ]] || { echo "--root requires a path" >&2; exit 2; }
      ROOT="${2%/}"
      START_SERVICES=0
      INSTALL_PACKAGES=0
      shift 2
      ;;
    --no-start)
      START_SERVICES=0
      shift
      ;;
    --no-packages)
      INSTALL_PACKAGES=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -x "$PAYLOAD/bin/pipanda" ]] || { echo "Installer payload is missing pipanda" >&2; exit 1; }
[[ -x "$PAYLOAD/bin/go2rtc" ]] || { echo "Installer payload is missing go2rtc" >&2; exit 1; }
[[ -f "$PAYLOAD/frontend/index.html" ]] || { echo "Installer payload is missing the frontend" >&2; exit 1; }

if [[ -z "$ROOT" ]]; then
  (( EUID == 0 )) || { echo "Run this installer as root with sudo" >&2; exit 1; }
  case "$(uname -m)" in
    aarch64|arm64) ;;
    *) echo "Unsupported architecture: $(uname -m); install 64-bit Raspberry Pi OS Lite" >&2; exit 1 ;;
  esac
fi

if (( INSTALL_PACKAGES )); then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update

  camera_package="rpicam-apps"
  if apt-cache show rpicam-apps-lite >/dev/null 2>&1; then
    camera_package="rpicam-apps-lite"
  fi
  apt-get install --yes --no-install-recommends \
    "$camera_package" ca-certificates curl nginx
fi

install -D -m 0755 "$PAYLOAD/bin/pipanda" "$ROOT/usr/local/bin/pipanda"
install -D -m 0755 "$PAYLOAD/bin/go2rtc" "$ROOT/usr/local/bin/go2rtc"
install -D -m 0755 "$PAYLOAD/deploy/pipanda-camera-source" \
  "$ROOT/usr/local/libexec/pipanda-camera-source"
install -D -m 0755 "$PAYLOAD/deploy/pipanda-camera-test" \
  "$ROOT/usr/local/bin/pipanda-camera-test"
install -D -m 0755 "$PAYLOAD/deploy/uninstall.sh" \
  "$ROOT/usr/local/bin/pipanda-uninstall"

# Frontend assets are content-addressed. Remove the previous build so obsolete
# hashes do not accumulate and index.html cannot refer to a mixed release.
rm -rf "$ROOT/usr/local/share/pipanda/frontend"
install -d -m 0755 "$ROOT/usr/local/share/pipanda/frontend"
cp -a "$PAYLOAD/frontend/." "$ROOT/usr/local/share/pipanda/frontend/"
find "$ROOT/usr/local/share/pipanda/frontend" -type d -exec chmod 0755 {} +
find "$ROOT/usr/local/share/pipanda/frontend" -type f -exec chmod 0644 {} +
if (( EUID == 0 )); then
  chown -R root:root "$ROOT/usr/local/share/pipanda/frontend"
fi
install -D -m 0644 "$PAYLOAD/VERSION" "$ROOT/usr/local/share/pipanda/VERSION"

install -D -m 0644 "$PAYLOAD/deploy/go2rtc.yaml" "$ROOT/etc/pipanda/go2rtc.yaml"
install -D -m 0644 "$PAYLOAD/deploy/pipanda.service" \
  "$ROOT/etc/systemd/system/pipanda.service"
install -D -m 0644 "$PAYLOAD/deploy/pipanda-camera.service" \
  "$ROOT/etc/systemd/system/pipanda-camera.service"
install -D -m 0644 "$PAYLOAD/deploy/nginx-pipanda.conf" \
  "$ROOT/etc/nginx/sites-available/pipanda"

# Preserve machine-specific settings and credentials during upgrades.
if [[ ! -e "$ROOT/etc/pipanda/pipanda.env" ]]; then
  install -D -m 0644 "$PAYLOAD/deploy/pipanda.env" "$ROOT/etc/pipanda/pipanda.env"
fi
if [[ ! -e "$ROOT/etc/pipanda/camera.env" ]]; then
  install -D -m 0644 "$PAYLOAD/deploy/camera.env" "$ROOT/etc/pipanda/camera.env"
fi

install -d -m 0755 "$ROOT/etc/nginx/sites-enabled"
ln -sfn ../sites-available/pipanda "$ROOT/etc/nginx/sites-enabled/pipanda"

if (( START_SERVICES )); then
  # Raspberry Pi OS ships this enabled; it conflicts with our default server.
  if [[ -L /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
  fi

  nginx -t
  systemctl daemon-reload
  systemctl enable --now nginx.service pipanda-camera.service pipanda.service
  systemctl restart nginx.service pipanda-camera.service pipanda.service

  for _ in {1..20}; do
    if curl --fail --silent --show-error http://127.0.0.1/api/v1/health >/dev/null; then
      break
    fi
    sleep 1
  done
  curl --fail --silent --show-error http://127.0.0.1/api/v1/health >/dev/null || {
    echo "PiPanda installed, but the backend health check failed" >&2
    echo "Inspect it with: journalctl -u pipanda.service -n 100" >&2
    exit 1
  }
  curl --fail --silent --show-error http://127.0.0.1/ >/dev/null || {
    echo "PiPanda installed, but nginx did not serve the frontend" >&2
    exit 1
  }
fi

version="$(<"$PAYLOAD/VERSION")"
cat <<EOF

PiPanda ${version} installed successfully.

Dashboard:     http://$(hostname).local/
Configuration: /etc/pipanda/pipanda.env
Backend logs:  journalctl -u pipanda.service -f
Camera logs:   journalctl -u pipanda-camera.service -f
Hardware test: sudo pipanda-camera-test
Uninstall:     sudo pipanda-uninstall

Open the dashboard, select Settings, and sign in to Bambu Lab.
EOF
