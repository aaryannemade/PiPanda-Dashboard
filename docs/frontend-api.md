# Frontend API

The API mirrors the information architecture visible in the Bambu Handy device
screen without claiming support for cloud-only features. JSON fields are stable;
unknown fields added by Bambu remain available in the raw printer and AMS
documents.

## Handy screen inventory

| Area | UI items shown | Backend source | Current support |
| --- | --- | --- | --- |
| Header | Printer name, online state, device selector, scan icon | Configuration and MQTT connection | Name and online state |
| Camera | Live printer image/video and page indicator | Pi Camera Module 3 through go2rtc | Player URL and stream name |
| Current job | Thumbnail, job name, profile subtitle, percentage, result, progress bar, layer count | Printer MQTT plus Bambu cloud history | Live name, state, progress, time and layers, plus plate render and model name from cloud history |
| Job actions | Print again and five-star rating | Bambu cloud history/model APIs | Advertised as unavailable |
| Nozzle and extruder | Current and target nozzle temperature, nozzle graphic, detail link | Printer MQTT | Read-only temperatures and nozzle diameter |
| Motion | XYZ controls and detail link | Printer command protocol | Advertised as unavailable |
| Light | Current state and toggle | Printer MQTT and `system.ledctrl` | Read and write |
| Additional controls | Bed temperature and cooling, auxiliary and chamber fans | Printer MQTT | Read-only values |
| Filament | AMS selector, external spool selector, humidity, active slot | Printer MQTT `ams` and `vt_tray` | Raw live values |
| AMS slots | Slot ID, material, color, remaining amount and active/loaded state | Printer MQTT tray objects | Raw live values |
| Filament library | Roll count and Add Filament | Bambu cloud filament library | Advertised as unavailable |
| Navigation | Models, Devices and Me tabs | Frontend routing and Bambu cloud account APIs | Frontend responsibility |

The screenshot's success history, print-again action, rating control and filament
library are not part of the printer's live MQTT status. They have nullable values
or `available: false` capability flags rather than placeholder data.

The job thumbnail and profile text are not in the MQTT status either, but they
are recoverable from the account's cloud print history and so are populated when
a login exists. See [`GET /api/v1/job/thumbnail`](#get-apiv1jobthumbnail).

## Running the API

```sh
zig build run -- serve --lan
```

The server defaults to `127.0.0.1:8080`. Configuration can be supplied with
flags or environment variables:

| Setting | Flag | Environment variable | Default |
| --- | --- | --- | --- |
| Bind address | `--bind` | `PIPANDA_HTTP_HOST` | `127.0.0.1` |
| Port | `--port` | `PIPANDA_HTTP_PORT` | `8080` |
| Display name | - | `PIPANDA_PRINTER_NAME` | `Panda` |
| Model label | - | `PIPANDA_PRINTER_MODEL` | `P1S` |
| Browser camera URL | - | `PIPANDA_CAMERA_URL` | Local go2rtc player URL |
| Printer transport | `--lan` | `PIPANDA_TRANSPORT` (`cloud` or `lan`) | `cloud` |

LAN mode also requires `PIPANDA_PRINTER_HOST`; `--lan` overrides the transport
environment setting. Cloud authentication remains
enabled on the printer, so using local MQTT does not disable Bambu Handy.

The server now binds and serves immediately, even with no stored credentials.
Bambu Lab login happens over the `/api/v1/auth/*` routes (below), which mirror
the `pipanda login` CLI state machine; once a token and a printer are stored the
server establishes the live printer session on its own. `serve` no longer
requires running `login` first.

The API still has no access control of its own. Keep it on loopback and expose
it through an authenticated reverse proxy rather than binding it directly to an
untrusted network. Browser calls are same-origin only: the API sends no wildcard
CORS header, because cross-origin access would let an unrelated web page operate
configured printer and Home Assistant controls. Use a reverse-proxy path rather
than a separate browser origin.

## Endpoints

### `GET /api/v1/dashboard`

Returns the complete frontend bootstrap document:

```json
{
  "api_version": 1,
  "printer": {
    "id": "01P...",
    "name": "Panda",
    "model": "P1S",
    "online": true,
    "state": "RUNNING",
    "wifi_signal": "-48dBm",
    "error_code": 0,
    "active_alerts": 0
  },
  "camera": {
    "available": true,
    "player_url": "http://127.0.0.1:1984/stream.html?src=p1s&mode=webrtc",
    "stream_name": "p1s"
  },
  "job": {
    "name": "Cute Mini Figurine Pack",
    "profile": "Goofy series – SNAIL Movable Eyes",
    "thumbnail_url": "/api/v1/job/thumbnail?v=1176981973",
    "state": "RUNNING",
    "result": null,
    "progress_percent": 73,
    "remaining_minutes": 18,
    "layer": 159,
    "total_layers": 218,
    "actions": { "print_again": false, "rating": false }
  },
  "controls": {
    "temperatures": {
      "nozzle": { "current": 220, "target": 220 },
      "bed": { "current": 55, "target": 55 },
      "chamber": { "current": null, "target": null }
    },
    "fans": {
      "cooling_percent": 100,
      "aux_percent": 70,
      "chamber_percent": 60
    },
    "light": { "available": true, "on": true },
    "motion": { "available": false },
    "extruder": { "available": false, "nozzle_diameter": "0.4" }
  },
  "filament": {
    "ams": {},
    "external_spool": null,
    "library": { "available": false, "roll_count": null }
  },
  "capabilities": {
    "light_control": true,
    "motion_control": false,
    "extruder_control": false,
    "print_again": false,
    "job_rating": false,
    "filament_library": false
  }
}
```

`filament.ams` preserves Bambu's accumulated `ams` object. Common tray fields
include `id`, `tray_type`, `tray_color`, `remain`, `tray_info_idx` and
`tray_sub_brands`; unit fields include `id`, `humidity`, `temp` and `tray`.
`tray_now`, `tray_pre` and `tray_tar` identify active and selected slots.

The P1S has no trustworthy chamber temperature probe, so chamber temperature is
always `null` even though its firmware reports a bogus value.

### `GET /api/v1/printer/state`

Returns the complete accumulated Bambu `print` document. This endpoint is for
diagnostics and forward-compatible frontend experiments; normal UI code should
use `/api/v1/dashboard`.

### `GET /api/v1/job/thumbnail`

Returns the plate render for the current job as `image/png` (or `image/jpeg` /
`image/webp`, whichever the cloud stored), and `404` with a `no_thumbnail` error
code when there is none.

Do not construct this URL by hand: use `job.thumbnail_url` from the dashboard
document, which carries a `?v=<task id>` query. The response is served
`immutable` with an `ETag`, so the browser refetches only when the task id
changes, and conditional requests get a `304`.

The image is not in the printer's MQTT status. It comes from the account's cloud
print history (`/v1/user-service/my/tasks`), whose `cover` link is a presigned S3
URL that **expires 30 minutes after it is issued** — which is why the backend
downloads the bytes and serves them itself rather than passing the link to the
browser. `job.profile` is resolved from the same record.

Consequences worth knowing:

- Both fields require a cloud login and working internet, even when the printer
  is reached over LAN transport. Without either they are `null` and the frontend
  falls back to its placeholder.
- The lookup runs only when the job name changes, roughly once per print. A
  failure backs off for about a minute rather than retrying every tick.
- When a print finishes, the last print's render stays cached, which matches what
  Handy shows.
- A print sliced and started entirely offline never reaches the cloud history and
  so has no render. Pulling the 3MF off the printer over FTPS would cover that
  case and is not implemented.

### `GET /api/v1/camera`

Returns `available`, `player_url`, `stream_name` and `transport`. This is camera
metadata, not a video relay; Zig never copies encoded video frames.

### `GET /api/v1/health`

Returns `status` and `printer_online`. `status` becomes `degraded` if the MQTT
status pump exits.

### `POST /api/v1/controls/light`

Accepts either UI-oriented boolean state:

```json
{ "on": true }
```

or an explicit printer mode:

```json
{ "mode": "flashing" }
```

The response is HTTP 202:

```json
{ "accepted": true, "mode": "on" }
```

Accepted means the QoS 1 MQTT command was published. It does not claim the
printer applied the command; the frontend should use the next dashboard state
update as confirmation.

## Home Assistant integration endpoints

These endpoints store where Home Assistant is, a long-lived access token, and
which entities the user cares about. Dashboard modals read temperatures and
control lights and fans on demand.

The token is a full-access credential for the user's home, so it is written
`0600` to `homeassistant.json` in the state directory and **is never returned by
any endpoint**. It lives in its own file rather than in `credentials.json`:
signing out of Bambu Lab must not discard the home automation setup.

### `GET /api/v1/integrations/homeassistant`

```json
{
  "configured": true,
  "base_url": "http://homeassistant.local:8123",
  "entities": {
    "light": ["light.kitchen_ceiling", "switch.desk_lamp"],
    "temperature": ["sensor.office_temperature"],
    "fan": ["fan.enclosure_extractor"]
  }
}
```

A corrupt or absent config reports `configured: false` rather than failing, so a
bad file cannot make the settings page unusable.

### `POST /api/v1/integrations/homeassistant`

```json
{
  "base_url": "http://homeassistant.local:8123",
  "token": "eyJhbGciOi…",
  "entities": { "light": [], "temperature": [], "fan": [] }
}
```

The connection is probed with `GET {base_url}/api/` **before** anything is
written, so a success response means the URL and token genuinely work rather
than merely that they were stored.

- `base_url` is normalised to a bare origin, so a trailing slash or a pasted
  `/lovelace/0` path is accepted.
- `token` may be omitted when editing entities at the same URL, which keeps the
  stored token. It is required the first time **and whenever the URL changes**;
  this prevents a caller from redirecting a stored bearer credential to another
  host.
- The grouping into `light` / `temperature` / `fan` is the user's, not Home
  Assistant's, so any domain is accepted: a bulb may be a `light.*` or a
  `switch.*`. Only the `domain.object_id` shape is enforced, and each group is
  capped at 64 entities.

Errors: `invalid_url`, `invalid_entity_id`, `duplicate_entity`,
`too_many_entities`, `missing_token`, and, from the probe, `ha_unauthorized`, `ha_unreachable` or
`ha_unexpected_response` as HTTP 502.

### `POST /api/v1/integrations/homeassistant/test`

Re-probes the stored configuration and returns `{"ok": true}`, so the settings
page can offer a connection test without the user re-entering the token.
Responds `409 not_configured` when nothing is stored.

### `POST /api/v1/integrations/homeassistant/disconnect`

Deletes the stored configuration. Succeeds even when there was nothing to
remove.

### `GET /api/v1/integrations/homeassistant/entities`

Fetches Home Assistant's `/api/states` registry on demand and returns only the
configured entities. This endpoint is called when an entity modal opens or is
refreshed; it is deliberately **not** part of `/api/v1/dashboard`, so an offline
Home Assistant cannot delay the printer's one-second status poll.

```json
{
  "entities": [
    {
      "entity_id": "light.desk",
      "group": "light",
      "name": "Desk lamp",
      "state": "on",
      "available": true,
      "unit": null,
      "value": null,
      "on": true,
      "brightness_percent": 50,
      "supports_brightness": true,
      "percentage": null,
      "supports_percentage": false
    },
    {
      "entity_id": "sensor.office_temperature",
      "group": "temperature",
      "name": "Office",
      "state": "21.75",
      "available": true,
      "unit": "°C",
      "value": 21.75,
      "on": null,
      "brightness_percent": null,
      "supports_brightness": false,
      "percentage": null,
      "supports_percentage": false
    }
  ]
}
```

The response follows the order saved in Settings. A configured id absent from
HA is retained with `available: false` and `state: "not found"`, so a typo is
visible rather than silently dropped. Brightness is converted from HA's 0–255
value to 0–100; fan percentage is already 0–100.

### `POST /api/v1/integrations/homeassistant/control`

Light and fan modals send tightly-scoped service calls:

```json
{ "group": "light", "entity_id": "light.desk", "on": true }
{ "group": "light", "entity_id": "light.desk", "on": true, "percentage": 40 }
{ "group": "fan", "entity_id": "fan.office", "on": true, "percentage": 55 }
```

- On/off maps to `{entity domain}.turn_on` / `turn_off`, so a light-group
  `switch.desk_plug` correctly calls `switch.turn_on`.
- Brightness maps to `light.turn_on` with `brightness_pct`; it is only allowed
  for `light.*` entities and only shown when HA advertises brightness support.
- Fan speed maps to `fan.set_percentage`; it is only shown when
  `FanEntityFeature.SET_SPEED` is advertised.
- Temperature entities are read-only.
- The requested entity must exist in the stored group. Arbitrary entity ids and
  arbitrary HA service names cannot be passed through this API.

Success is HTTP 202 with `{"accepted": true}`. The modal refetches states after
the service call rather than assuming HA applied it.

> **https with a self-signed certificate will not work.** The client verifies
> against the system CA bundle, so a local Home Assistant should be reached over
> `http://` on the LAN, or over `https://` with a certificate that actually
> validates. This is deliberate: unlike the printer's own certificate, there is
> no reason to accept an unverified one here.

## Authentication endpoints

These drive the same Bambu Lab cloud login flow as `pipanda login`, so the
settings page can authenticate without touching the CLI. Until login completes
and a printer is selected, `/api/v1/dashboard`, `/api/v1/printer/state` and
`/api/v1/controls/light` answer `503 not_connected`.

### `GET /api/v1/auth/status`

Snapshot of the auth state, used to render the settings page on load:

```json
{
  "authenticated": true,
  "account": "you@example.com",
  "device_id": "01P...",
  "device_selected": true,
  "connected": true,
  "online": true,
  "pending": null
}
```

`pending` is `"code"` or `"tfa"` when a login step is awaiting a follow-up,
otherwise `null`. `connected` reflects whether the live printer session is up.

### `POST /api/v1/auth/login`

Step one. Body:

```json
{ "account": "you@example.com", "password": "…", "region": "global", "code_login": false }
```

`region` is `"global"` (default) or `"china"`. Set `code_login` to `true`, or
omit the password, to skip straight to the emailed/texted-code flow for accounts
with no password. The response reports the next step:

```json
{ "result": "authenticated" }
```

`result` is one of `authenticated` (token stored), `code_required` (a code has
been sent — call `/auth/code`) or `tfa_required` (an authenticator app is
enrolled — call `/auth/tfa`).

### `POST /api/v1/auth/code`

Step two for emailed/texted codes. Body `{ "code": "123456" }`. Returns
`{ "result": "authenticated" }` on success.

### `POST /api/v1/auth/tfa`

Step two for authenticator apps. Body `{ "code": "123456" }`. Returns
`{ "result": "authenticated" }` on success.

### `GET /api/v1/auth/devices`

The printers bound to the logged-in account, so the frontend can offer a
selector when there is more than one:

```json
{
  "devices": [
    { "dev_id": "01P...", "name": "Panda", "online": true, "model": "P1S", "selected": true }
  ]
}
```

### `POST /api/v1/auth/select`

Chooses the printer to watch and caches its LAN access code. Body
`{ "device_id": "01P..." }`. Returns `{ "selected": true }` and reconnects the
live session against the new printer. A single-printer account is selected
automatically at login, so this is only needed when several printers exist.

### `POST /api/v1/auth/logout`

Discards the stored token, tears down the live session, and returns
`{ "logged_out": true }`.

Login errors reuse the standard error shape with codes such as
`invalid_credentials`, `code_incorrect`, `code_expired`, `cloudflare_blocked`,
`cloud_unreachable` and `not_authenticated`.

All endpoints support `OPTIONS`; GET endpoints also support `HEAD`. Errors use
the shape `{"error":{"code":"...","message":"..."}}`.

## Frontend refresh model

Poll `/api/v1/dashboard` once per second for the first frontend implementation.
The backend serves its accumulated local state and does not issue an expensive
`pushall` per request. Server-sent events or WebSockets can be added later
without changing the dashboard document.
