# AGENTS.md

pipanda: auxiliary dashboard for a Bambu Lab P1S, hosted on a Raspberry Pi Zero 2 W.
Zig backend (CLI + HTTP API) + SolidJS frontend + Raspberry Pi OS deployment scripts.
It is a custom, extensible replacement for Bambu Handy — the printer protocol is
undocumented and reverse engineered, so treat working protocol code as load-bearing.

## Toolchain is not on PATH

Nothing (`zig`, `bun`, `just`, `shellcheck`, `yq`) is installed globally. Every
command must go through the flake dev shell:

```sh
nix develop --command just check
nix develop --command zig build run -- watch --lan
```

The shell also exports `ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-cache/global` and
`PIPANDA_STATE_DIR=$PWD/.state`. Running `zig` outside it will miss both.

## Commands

| Task | Command |
| --- | --- |
| Fast full check | `just check` (= `fmt-check` -> `typecheck` -> `test` -> `web-check`) |
| Full local CI | `just ci` (adds `web-build`, `camera-check`, `cross-pi`, `flake-check`) |
| Format | `just fmt` (`zig fmt src build.zig` + `nix fmt flake.nix`) |
| Type-check Zig only | `zig build check` (no binary emitted; also what zls uses) |
| Unit tests | `zig build test --summary all` |
| Frontend deps | `just install` (bun, `--frozen-lockfile`; never npm/pnpm/yarn) |
| Frontend typecheck | `just web-check` (`tsc --noEmit`) |

`build.zig` wires no test filter, so `zig build test` is all-or-nothing. For fast
iteration use `zig test src/root.zig`: it runs every module test in seconds
without the build graph. `zig test` on a single file only works for files that
import nothing outside their own directory (`status.zig`, `log.zig`,
`tls_stream.zig`); anything reaching for `../log.zig` fails with "import of file
outside module path". Only `src/main.zig` needs the `pipanda` module, so its
tests require `zig build test`.

`.github/workflows/pi-release.yml` reproduces `just check` inline; keep the two in
sync when adding a check.

## Zig 0.16 async std.Io — the biggest trap

`build.zig.zon` pins `minimum_zig_version = 0.16.0`. This codebase uses the new
`Io` interface everywhere, not the pre-0.15 blocking std:

- entrypoint is `pub fn main(init: std.process.Init) !void`; `init` carries `gpa`,
  `arena`, `io`, `environ_map`, and `minimal.args` — do not add `std.process.argsAlloc`
  or `std.os.getenv`
- `Io` is threaded through explicitly (`printer.Session`, `credentials.Store`, `api.serve`)
- concurrency is `Io.Group` + `tasks.concurrent(io, fn, args)`, not `std.Thread`
- sockets are `Io.net.IpAddress` / `listener.accept(io)`; files are `Io.File.Writer`;
  locks are `Io.Mutex` (`lock(io)`), not `std.Thread.Mutex`

Model-suggested pre-0.16 std APIs will not compile. Check an existing call site
(`src/api.zig:73`, `src/main.zig:46`) before inventing one.

## Layout

- `src/root.zig` — the `pipanda` module: the reusable core (`cloud`, `credentials`,
  `printer`, `status`, `api`, `mqtt`, `tls_stream`). Its `test {}` block re-exports
  every submodule; a new file must be added there or its tests never run.
- `src/main.zig` — CLI only, the module's consumer. Keep logic out of it.
- `src/api.zig` — HTTP API on `/api/v1/*`; routes are matched in `route()` and each
  new route needs an entry in the `Route` enum plus the routing test.
- `frontend/src` — SolidJS (not React); `api.ts` client, `lib/dashboard.ts` projection,
  `components/`. Vite proxies `/api` to `127.0.0.1:8080`; set `VITE_API_BASE` only for
  cross-origin deployments.
- `deploy/pi-os/` — installer, systemd units, nginx site, go2rtc config.
- `docs/frontend-api.md` — endpoint contract, env var table, capability flags.

## Domain constraints (do not "fix" these)

- **Status is a JSON document, not structs.** P1 `print.push_status` sends only
  changed fields, so `status.zig` deep-merges reports into an accumulated
  `std.json.ObjectMap`. Objects merge key-by-key; arrays are replaced wholesale
  (the printer resends whole arrays). Mirroring Bambu's ~150 undocumented fields
  into structs would silently drop firmware additions. `Snapshot` is the typed view.
- **The status arena is rebuilt every 512 merges** because merging leaks the
  replaced values. That interval matters on a 512 MB Pi running for weeks.
- **Never request `pushall` on a loop.** Full-status serialisation stalls the P1's
  MCU and visibly stutters prints; it is sent once at connect, then deltas only.
- **`cloud.zig` impersonates Orca Slicer** (`User-Agent` and `X-BBL-*` headers) to get
  past Cloudflare. Do not tidy those headers away.
- **LAN mode skips TLS verification deliberately** — the printer's self-signed cert
  is not issued for the address dialled. Cloud mode is fully verified; keep it that way.
- **Secrets never reach logs.** Diagnostics go through `src/log.zig` (`--verbose`
  gated); tokens are never printed, MQTT usernames only as a 4-char prefix + length,
  LAN codes only as a length. Use `log.prefix` rather than logging raw credentials.
  `.state/` and the token file (mode `0600`) are gitignored.
- The API has **no access control**; it must stay on loopback behind nginx.

## Pi release path

- Cross-compile is `zig build -Dtarget=aarch64-linux-musl -Dcpu=baseline
  -Doptimize=ReleaseSafe`. `-Dcpu=baseline` is mandatory: the Pi Zero 2 W `SIGILL`s on
  optional `aes`/`sha`/`pmull` instructions, and CI has an `objdump` gate that fails
  the build if they appear.
- Releases are **manual only**: GitHub Actions -> "Build Raspberry Pi installer" ->
  semver input. There is no tag-push trigger. go2rtc is downloaded at a pinned
  version with a pinned SHA-256 in the workflow env.
- Shell assets must pass `bash -n` **and** `shellcheck`; `just camera-check` also
  lints both go2rtc YAMLs and runs `deploy/pi-os/tests/run.sh`, which stubs
  `rpicam-vid` on `PATH` and asserts the exact encoder arguments. Changing
  `pipanda-camera-source` flags means updating that expectation list.
- `frontend/dist/` and `zig-out/` are gitignored build artifacts; do not commit them.

## Runtime configuration

`PIPANDA_TRANSPORT` (`cloud`|`lan`), `PIPANDA_PRINTER_HOST` (required for LAN),
`PIPANDA_HTTP_HOST`/`PIPANDA_HTTP_PORT`, `PIPANDA_PRINTER_NAME`/`_MODEL`,
`PIPANDA_CAMERA_URL`, `PIPANDA_STATE_DIR`. `--lan` overrides `PIPANDA_TRANSPORT`.
On the Pi these live in `/etc/pipanda/pipanda.env`; state in `/var/lib/pipanda`.

Bambu access tokens last ~3 months and the refresh endpoint is dead — expiry is
fixed by running `login` again, not by writing refresh logic.

## Known gaps (from README, still true)

Reconnection is not automatic (`watch` exits on drop); authenticator-app login is
implemented but untested; timelapse recording and the Home Assistant integration
are not started.
