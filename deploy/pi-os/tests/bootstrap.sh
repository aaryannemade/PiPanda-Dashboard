#!/bin/bash
# Offline bootstrap tests: all downloads and sudo calls are stubbed.
set -euo pipefail
MODULE_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# == 1 ]] || { echo "Usage: $0 TEST_INSTALLER" >&2; exit 2; }
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/assets" "$tmp/downloads"
cp "$1" "$tmp/assets/pipanda-latest-aarch64.run"
(cd "$tmp/assets" && sha256sum pipanda-latest-aarch64.run >pipanda-latest-aarch64.run.sha256)

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
url=""
while (($#)); do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[[ "$url" == https://github.com/aaryannemade/pipanda-dashboard/releases/latest/download/* ]]
file="${url##*/}"
printf '%s\n' "$file" >>"$PIPANDA_TEST_BOOTSTRAP_LOG"
if [[ "${PIPANDA_TEST_DOWNLOAD_FAIL:-}" == "$file" ]]; then
  printf 'partial download\n' >"$output"
  exit 22
fi
cp "$PIPANDA_TEST_ASSETS/$file" "$output"
EOF
cat >"$tmp/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo sudo >>"$PIPANDA_TEST_BOOTSTRAP_LOG"
# Tests always use --root, which stages without requiring real privilege.
"$@"
EOF
chmod +x "$tmp/bin/curl" "$tmp/bin/sudo"
export PATH="$tmp/bin:$PATH" TMPDIR="$tmp/downloads"
export PIPANDA_TEST_ASSETS="$tmp/assets" PIPANDA_TEST_BOOTSTRAP_LOG="$tmp/log"

# Help is local: no downloads or sudo.
bash "$MODULE_DIR/bootstrap.sh" --help >"$tmp/help"
test ! -e "$tmp/log"

# Exercise stdin execution and argument forwarding (including spaces in paths).
bash -s -- --root "$tmp/staged install" <"$MODULE_DIR/bootstrap.sh" >"$tmp/output"
test -x "$tmp/staged install/usr/local/bin/pipanda"
test "$(grep -c '^pipanda-latest-aarch64.run' "$tmp/log")" = 2
test -z "$(find "$tmp/downloads" -mindepth 1 -print -quit)"

for file in pipanda-latest-aarch64.run pipanda-latest-aarch64.run.sha256; do
  : >"$tmp/log"
  if PIPANDA_TEST_DOWNLOAD_FAIL="$file" bash "$MODULE_DIR/bootstrap.sh" --root "$tmp/failed" >"$tmp/output" 2>&1; then
    echo "bootstrap accepted a failed download" >&2; exit 1
  fi
  test ! -e "$tmp/failed"
  if grep -Fx sudo "$tmp/log"; then echo "bootstrap escalated before verification" >&2; exit 1; fi
  test -z "$(find "$tmp/downloads" -mindepth 1 -print -quit)"
done

# A valid digest for different bytes and malformed checksum data both fail shut.
cp "$tmp/assets/pipanda-latest-aarch64.run.sha256" "$tmp/good.sha256"
printf 'corruption\n' >>"$tmp/assets/pipanda-latest-aarch64.run"
for checksum in mismatch malformed; do
  if [[ "$checksum" == malformed ]]; then printf 'invalid checksum\n' >"$tmp/assets/pipanda-latest-aarch64.run.sha256"; fi
  : >"$tmp/log"
  if bash "$MODULE_DIR/bootstrap.sh" --root "$tmp/failed" >"$tmp/output" 2>&1; then
    echo "bootstrap accepted $checksum checksum" >&2; exit 1
  fi
  test ! -e "$tmp/failed"
  if grep -Fx sudo "$tmp/log"; then echo "bootstrap escalated before verification" >&2; exit 1; fi
  test -z "$(find "$tmp/downloads" -mindepth 1 -print -quit)"
done

# Propagate installer errors too, and still clean the downloaded payload.
cp "$1" "$tmp/assets/pipanda-latest-aarch64.run"
cp "$tmp/good.sha256" "$tmp/assets/pipanda-latest-aarch64.run.sha256"
status=0
bash "$MODULE_DIR/bootstrap.sh" --unknown-option >"$tmp/output" 2>&1 || status=$?
test "$status" = 2
test -z "$(find "$tmp/downloads" -mindepth 1 -print -quit)"
echo "Bootstrap tests passed"
