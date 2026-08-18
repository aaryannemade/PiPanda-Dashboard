#!/bin/bash
set -euo pipefail

if (( EUID != 0 )); then
  echo "Run this uninstaller as root: sudo ./uninstall.sh" >&2
  exit 1
fi

systemctl disable --now pipanda.service pipanda-camera.service 2>/dev/null || true

rm -f \
  /etc/nginx/sites-enabled/pipanda \
  /etc/nginx/sites-available/pipanda \
  /etc/systemd/system/pipanda.service \
  /etc/systemd/system/pipanda-camera.service \
  /usr/local/bin/pipanda \
  /usr/local/bin/pipanda-uninstall \
  /usr/local/bin/go2rtc \
  /usr/local/bin/pipanda-camera-test \
  /usr/local/libexec/pipanda-camera-source

rm -rf /usr/local/share/pipanda

systemctl daemon-reload
systemctl reload nginx.service 2>/dev/null || true

cat <<'EOF'
PiPanda dashboard and camera services removed.

Configuration and credentials were preserved. Remove them manually if unwanted:
  sudo rm -rf /etc/pipanda
  sudo rm -rf /var/lib/pipanda /var/lib/private/pipanda
EOF
