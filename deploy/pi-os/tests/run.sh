#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"

cat >"$tmp/bin/rpicam-vid" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$PIPANDA_TEST_ARGS"
printf '\x00\x00\x00\x01fake-h264'
EOF
chmod +x "$tmp/bin/rpicam-vid"

cp "$MODULE_DIR/camera.env" "$tmp/camera.env"
export PIPANDA_CAMERA_CONFIG="$tmp/camera.env"
export PIPANDA_TEST_ARGS="$tmp/args"
export PATH="$tmp/bin:$PATH"

bash "$MODULE_DIR/pipanda-camera-source" >"$tmp/video.h264"

[[ -s "$tmp/video.h264" ]] || {
  echo "camera source produced no output" >&2
  exit 1
}

for expected in \
  h264 baseline 4.1 1920 1080 30 4000000 continuous -; do
  grep --fixed-strings --line-regexp -- "$expected" "$tmp/args" >/dev/null || {
    echo "camera source omitted expected argument: $expected" >&2
    exit 1
  }
done

cat >>"$tmp/camera.env" <<'EOF'
HORIZONTAL_FLIP=1
VERTICAL_FLIP=1
EOF
bash "$MODULE_DIR/pipanda-camera-source" >"$tmp/video.h264"
grep --fixed-strings --line-regexp -- --hflip "$tmp/args" >/dev/null
grep --fixed-strings --line-regexp -- --vflip "$tmp/args" >/dev/null

sed -i 's/^WIDTH=.*/WIDTH=3840/' "$tmp/camera.env"
if bash "$MODULE_DIR/pipanda-camera-source" >/dev/null 2>"$tmp/error"; then
  echo "camera source accepted an unsupported width" >&2
  exit 1
fi
grep --fixed-strings "limited here to 1920x1080" "$tmp/error" >/dev/null

bash "$MODULE_DIR/install.sh" --help >/dev/null

echo "Pi OS camera module tests passed"
