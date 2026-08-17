#!/bin/bash
set -euo pipefail

if (( EUID != 0 )); then
  echo "Run this uninstaller as root: sudo ./uninstall.sh" >&2
  exit 1
fi

systemctl disable --now pipanda-camera.service 2>/dev/null || true

rm -f \
  /etc/systemd/system/pipanda-camera.service \
  /usr/local/bin/go2rtc \
  /usr/local/bin/pipanda-camera-test \
  /usr/local/libexec/pipanda-camera-source

systemctl daemon-reload

cat <<'EOF'
PiPanda camera service removed.

Configuration was preserved in /etc/pipanda. Remove it manually if unwanted:
  sudo rm -rf /etc/pipanda
EOF
