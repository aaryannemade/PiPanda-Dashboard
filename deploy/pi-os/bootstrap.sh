#!/bin/bash
# Download without privilege, verify, then invoke the existing Pi installer.
# Keep execution inside a function so a truncated pipe cannot run half a script.
main() (
  set -euo pipefail
  umask 077

  if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    cat <<'EOF'
Usage: bash install.sh [installer options]

Install or update PiPanda from the latest GitHub Release.
Downloads and verifies the installer before requesting sudo.
Requires 64-bit Raspberry Pi OS, curl, and sha256sum.

Options forwarded to the installer:
  --no-start      install without enabling or starting services
  --no-packages   skip package installation
  --root PATH     stage files below PATH instead of installing on this host
EOF
    exit 0
  fi

  for tool in curl sha256sum mktemp; do
    command -v "$tool" >/dev/null || { echo "pipanda: required command missing: $tool" >&2; exit 1; }
  done
  if (( EUID != 0 )); then
    command -v sudo >/dev/null || { echo "pipanda: sudo is required to install" >&2; exit 1; }
  fi

  base="https://github.com/aaryannemade/pipanda-dashboard/releases/latest/download"
  installer="pipanda-latest-aarch64.run"
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT

  echo "Downloading the latest PiPanda installer..."
  for file in "$installer" "$installer.sha256"; do
    curl --fail --silent --show-error --location \
      --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 \
      --output "$tmp/$file" "$base/$file"
  done

  # Verify only our downloaded file, never paths supplied by a checksum file.
  read -r digest _ <"$tmp/$installer.sha256"
  if [[ ! "$digest" =~ ^[[:xdigit:]]{64}$ ]]; then
    echo "pipanda: invalid installer checksum; nothing was installed" >&2
    exit 1
  fi
  if ! (cd "$tmp" && printf '%s  %s\n' "$digest" "$installer" | sha256sum --check); then
    echo "pipanda: checksum mismatch; nothing was installed. Retry to fetch a matching release pair." >&2
    exit 1
  fi

  if (( EUID == 0 )); then
    bash "$tmp/$installer" "$@"
  else
    sudo bash "$tmp/$installer" "$@"
  fi
)

main "$@"
