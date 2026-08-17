#!/bin/bash
set -euo pipefail

readonly GO2RTC_VERSION="1.9.14"
readonly GO2RTC_ARM64_SHA256="359fabade8a7a51e81a55fe6df6b0ef81764a5e1d63179577534eaaa71904b50"
readonly GO2RTC_ARM_SHA256="4d7e1639af5a2722a28e864468fd8099b3c1682565446c798bf9e3b38fde12e4"

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${DESTDIR:-}"
START_SERVICE=1
INSTALL_PACKAGES=1

usage() {
  cat <<'EOF'
Usage: sudo ./install.sh [options]

Install the PiPanda camera module on Raspberry Pi OS Lite.

Options:
  --root PATH       stage files below PATH instead of installing on this host
  --no-start        install but do not enable/start the systemd service
  --no-packages     do not install rpicam-apps-lite/curl with apt
  -h, --help        show this help

Environment:
  GO2RTC_BINARY     use this local go2rtc binary instead of downloading one
EOF
}

while (($#)); do
  case "$1" in
    --root)
      [[ $# -ge 2 ]] || { echo "--root requires a path" >&2; exit 2; }
      ROOT="${2%/}"
      START_SERVICE=0
      INSTALL_PACKAGES=0
      shift 2
      ;;
    --no-start)
      START_SERVICE=0
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

if [[ -z "$ROOT" && $EUID -ne 0 ]]; then
  echo "Run this installer as root: sudo ./install.sh" >&2
  exit 1
fi

if (( INSTALL_PACKAGES )); then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update

  camera_package="rpicam-apps"
  if apt-cache show rpicam-apps-lite >/dev/null 2>&1; then
    camera_package="rpicam-apps-lite"
  fi
  apt-get install --yes --no-install-recommends \
    "$camera_package" ca-certificates curl
fi

case "$(uname -m)" in
  aarch64|arm64)
    go2rtc_asset="go2rtc_linux_arm64"
    go2rtc_sha256="$GO2RTC_ARM64_SHA256"
    ;;
  armv7l|armv8l)
    go2rtc_asset="go2rtc_linux_arm"
    go2rtc_sha256="$GO2RTC_ARM_SHA256"
    ;;
  *)
    if [[ -z "$ROOT" ]]; then
      echo "Unsupported architecture: $(uname -m); use 64-bit Raspberry Pi OS Lite" >&2
      exit 1
    fi
    # Staging on a development workstation targets the recommended 64-bit OS.
    go2rtc_asset="go2rtc_linux_arm64"
    go2rtc_sha256="$GO2RTC_ARM64_SHA256"
    ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [[ -n "${GO2RTC_BINARY:-}" ]]; then
  cp "$GO2RTC_BINARY" "$tmp/go2rtc"
else
  url="https://github.com/AlexxIT/go2rtc/releases/download/v${GO2RTC_VERSION}/${go2rtc_asset}"
  echo "Downloading go2rtc v${GO2RTC_VERSION} for ${go2rtc_asset}..."
  curl --fail --location --proto '=https' --tlsv1.2 \
    --output "$tmp/go2rtc" "$url"
fi

printf '%s  %s\n' "$go2rtc_sha256" "$tmp/go2rtc" | sha256sum --check --status || {
  echo "go2rtc checksum verification failed" >&2
  exit 1
}

install -D -m 0755 "$tmp/go2rtc" "$ROOT/usr/local/bin/go2rtc"
install -D -m 0755 "$SCRIPT_DIR/pipanda-camera-source" \
  "$ROOT/usr/local/libexec/pipanda-camera-source"
install -D -m 0755 "$SCRIPT_DIR/pipanda-camera-test" \
  "$ROOT/usr/local/bin/pipanda-camera-test"
install -D -m 0644 "$SCRIPT_DIR/go2rtc.yaml" \
  "$ROOT/etc/pipanda/go2rtc.yaml"
install -D -m 0644 "$SCRIPT_DIR/pipanda-camera.service" \
  "$ROOT/etc/systemd/system/pipanda-camera.service"

# Preserve local tuning on upgrades.
if [[ ! -e "$ROOT/etc/pipanda/camera.env" ]]; then
  install -D -m 0644 "$SCRIPT_DIR/camera.env" \
    "$ROOT/etc/pipanda/camera.env"
fi

if (( START_SERVICE )); then
  systemctl daemon-reload
  systemctl enable --now pipanda-camera.service
fi

cat <<EOF

PiPanda camera module installed.

Configuration: /etc/pipanda/camera.env
Service logs:  journalctl -u pipanda-camera.service -f
Hardware test: sudo pipanda-camera-test
WebRTC test:   http://<pi-address>:1984/stream.html?src=p1s&mode=webrtc
EOF
