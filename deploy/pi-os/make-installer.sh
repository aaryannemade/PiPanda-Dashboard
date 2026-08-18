#!/bin/bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo "Usage: $0 VERSION PIPANDA_BINARY FRONTEND_DIR GO2RTC_BINARY OUTPUT" >&2
  exit 2
fi

VERSION="${1#v}"
PIPANDA_BINARY="$2"
FRONTEND_DIR="$3"
GO2RTC_BINARY="$4"
OUTPUT="$5"
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
  echo "Invalid version '$VERSION'; expected a semantic version such as 1.2.3" >&2
  exit 2
}
[[ -x "$PIPANDA_BINARY" ]] || { echo "Backend binary not executable: $PIPANDA_BINARY" >&2; exit 1; }
[[ -f "$FRONTEND_DIR/index.html" ]] || { echo "Frontend index missing: $FRONTEND_DIR/index.html" >&2; exit 1; }
[[ -x "$GO2RTC_BINARY" ]] || { echo "go2rtc binary not executable: $GO2RTC_BINARY" >&2; exit 1; }

output_parent="$(dirname -- "$OUTPUT")"
[[ -d "$output_parent" ]] || { echo "Output directory does not exist: $output_parent" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
stage="$tmp/stage"
mkdir -p "$stage/payload/bin" "$stage/payload/frontend" "$stage/payload/deploy"

install -m 0755 "$SCRIPT_DIR/bundle-install.sh" "$stage/install.sh"
install -m 0755 "$PIPANDA_BINARY" "$stage/payload/bin/pipanda"
install -m 0755 "$GO2RTC_BINARY" "$stage/payload/bin/go2rtc"
cp -a "$FRONTEND_DIR/." "$stage/payload/frontend/"
printf '%s\n' "$VERSION" >"$stage/payload/VERSION"

for file in \
  camera.env \
  nginx-pipanda.conf \
  pipanda.env \
  pipanda-camera-source \
  pipanda-camera-test \
  pipanda-camera.service \
  pipanda.service \
  uninstall.sh; do
  cp "$SCRIPT_DIR/$file" "$stage/payload/deploy/$file"
done
cp "$SCRIPT_DIR/go2rtc-dashboard.yaml" "$stage/payload/deploy/go2rtc.yaml"

tar -C "$stage" -czf "$tmp/payload.tar.gz" .

cat >"$OUTPUT" <<'EOF'
#!/bin/bash
set -euo pipefail

marker="__PIPANDA_ARCHIVE_BELOW__"
archive_line="$(awk -v marker="$marker" '$0 == marker { print NR + 1; exit }' "$0")"
[[ -n "$archive_line" ]] || { echo "Installer payload marker not found" >&2; exit 1; }

if [[ "${1:-}" == "--extract" ]]; then
  [[ $# -eq 2 ]] || { echo "Usage: $0 --extract DIRECTORY" >&2; exit 2; }
  mkdir -p "$2"
  tail -n +"$archive_line" "$0" | tar -xzf - -C "$2"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tail -n +"$archive_line" "$0" | tar -xzf - -C "$tmp"
bash "$tmp/install.sh" "$@"
exit 0
__PIPANDA_ARCHIVE_BELOW__
EOF
cat "$tmp/payload.tar.gz" >>"$OUTPUT"
chmod 0755 "$OUTPUT"

echo "Created $OUTPUT"
