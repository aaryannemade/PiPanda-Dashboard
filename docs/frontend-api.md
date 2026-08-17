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
| Current job | Thumbnail, job name, profile subtitle, percentage, result, progress bar, layer count | Printer MQTT plus Bambu cloud history | Live name, state, progress, time and layers |
| Job actions | Print again and five-star rating | Bambu cloud history/model APIs | Advertised as unavailable |
| Nozzle and extruder | Current and target nozzle temperature, nozzle graphic, detail link | Printer MQTT | Read-only temperatures and nozzle diameter |
| Motion | XYZ controls and detail link | Printer command protocol | Advertised as unavailable |
| Light | Current state and toggle | Printer MQTT and `system.ledctrl` | Read and write |
| Additional controls | Bed temperature and cooling, auxiliary and chamber fans | Printer MQTT | Read-only values |
| Filament | AMS selector, external spool selector, humidity, active slot | Printer MQTT `ams` and `vt_tray` | Raw live values |
| AMS slots | Slot ID, material, color, remaining amount and active/loaded state | Printer MQTT tray objects | Raw live values |
| Filament library | Roll count and Add Filament | Bambu cloud filament library | Advertised as unavailable |
| Navigation | Models, Devices and Me tabs | Frontend routing and Bambu cloud account APIs | Frontend responsibility |

The screenshot's job thumbnail, profile text, success history, print-again action,
rating control and filament library are not part of the printer's live MQTT
status. They have nullable values or `available: false` capability flags rather
than placeholder data.

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

LAN mode also requires `PIPANDA_PRINTER_HOST`. Cloud authentication remains
enabled on the printer, so using local MQTT does not disable Bambu Handy.

The API has no authentication. Keep it on loopback and expose it through the
future authenticated frontend/reverse proxy rather than binding it directly to
an untrusted network.

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
    "profile": null,
    "thumbnail_url": null,
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

All endpoints support `OPTIONS`; GET endpoints also support `HEAD`. Errors use
the shape `{"error":{"code":"...","message":"..."}}`.

## Frontend refresh model

Poll `/api/v1/dashboard` once per second for the first frontend implementation.
The backend serves its accumulated local state and does not issue an expensive
`pushall` per request. Server-sent events or WebSockets can be added later
without changing the dashboard document.
