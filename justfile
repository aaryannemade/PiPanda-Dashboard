set shell := ["bash", "-euo", "pipefail", "-c"]

# Show available development commands.
default:
    @just --list

# Build the native pipanda binary.
build *args:
    zig build {{args}}

# Pass arguments directly to the pipanda CLI.
run *args:
    zig build run -- {{args}}

# Format Zig and Nix sources.
fmt:
    zig fmt src build.zig
    nix fmt -- flake.nix

# Check formatting without changing files.
fmt-check:
    zig fmt --check src build.zig
    nix fmt -- --check flake.nix

# Type-check the Zig executable without emitting it.
typecheck:
    zig build check

# Run all Zig unit tests.
test:
    zig build test --summary all

# Run the fast backend development checks.
check: fmt-check typecheck test

# Authenticate with Bambu Lab.
login:
    zig build run -- login

# Authenticate using an emailed code.
login-code:
    zig build run -- login --code

# List printers bound to the account.
devices:
    zig build run -- devices

# Stream printer status; pass --lan, --json, or --raw as needed.
watch *args:
    zig build run -- watch {{args}}

# Run the frontend API; pass --lan, --bind, or --port as needed.
serve *args:
    zig build run -- serve {{args}}

# Set the chamber light to on, off, or flashing.
light state:
    zig build run -- light {{state}}

# Validate the Raspberry Pi OS camera deployment scripts and configuration.
camera-check:
    bash -n deploy/pi-os/*.sh deploy/pi-os/pipanda-camera-source deploy/pi-os/pipanda-camera-test deploy/pi-os/tests/*.sh
    shellcheck deploy/pi-os/*.sh deploy/pi-os/pipanda-camera-source deploy/pi-os/pipanda-camera-test deploy/pi-os/tests/*.sh
    yq eval deploy/pi-os/go2rtc.yaml >/dev/null
    bash deploy/pi-os/tests/run.sh

# Cross-compile a static ReleaseSafe binary for the 64-bit Pi Zero 2 W.
cross-pi:
    zig build -Dtarget=aarch64-linux-musl -Dcpu=cortex_a53 -Doptimize=ReleaseSafe

# Evaluate all flake outputs without building them.
flake-check:
    nix flake check --no-build

# Run the complete local validation suite.
ci: check camera-check cross-pi flake-check
