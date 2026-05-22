# FreeTube HTTP API

All endpoints are served by `freetube_http.Server`. JSON in, JSON out unless
noted. Errors are returned as plain-text bodies with the appropriate HTTP
status code.

## CORS

Every response carries permissive CORS headers
(`Access-Control-Allow-Origin: *` or echoed `Origin`, `*-Allow-Methods`
covering GET/POST/PUT/DELETE/HEAD/OPTIONS, `*-Allow-Headers` covering
`content-type, accept`). `OPTIONS` preflights return `204 No Content`
with the same headers. This lets the browser plugin (origin
`https://www.youtube.com`) call the server cross-origin.

## Session model

A **session** is `{ source: Stream_source.t; sink: Sink.t }` with an
identity (`session_id`) and idle timestamps. The source produces HLS bytes
from a YouTube selection; the sink consumes them — either the HTTP client
itself (`Url_consumer`) or a cast device (`Airplay`, `Dlna`).

Sessions are idle-GC'd after 60 seconds of no activity.

## Endpoints

### Sessions

#### `POST /sessions`

Create a session. Wires up a source pipeline and (optionally) attaches
a sink in one call.

Request:
```json
{
  "source": ["youtube_id", "dQw4w9WgXcQ"],
  "sink":   "living-room-tv",
  "vcodecs": ["hevc", "avc"],
  "acodecs": ["aac"],
  "cookies": [
    { "domain": ".youtube.com", "name": "SAPISID", "value": "...",
      "path": "/", "secure": true, "include_subdomains": true, "expires": 0 }
  ]
}
```

- `source` — tuple-tagged ADT, exactly one of:
  - `["youtube_id", "<id>"]` — resolve streams via `yt-dlp`.
  - `["youtube_file", "<url>"]` — fetch a yt-dlp-shaped streams JSON
    from the URL (used by tests and clients that resolve YouTube
    themselves).
  - `["url", "<url>"]` — no producer; the sink plays `<url>` directly.
    Requires a device sink.
- `sink` — device id (matched the same way as `/devices`), or `null`
  for "no device" (HTTP-pull only).
- `vcodecs` / `acodecs` — optional string lists. When present they
  **override the sink device's codec capabilities**, and the effective
  list drives source selection. Precedence: request → device →
  defaults.
- `cookies` — optional list of cookies forwarded to `yt-dlp` as a
  Netscape-format cookie jar. Used by the browser plugin to pass the
  caller's `.youtube.com` cookies so age-, region-, and login-gated
  streams resolve. Each entry: `{ domain, name, value, path?, secure?,
  include_subdomains?, expires? }`. Only meaningful for
  `source = ["youtube_id", _]`.

Response `200`:
```json
{
  "session_id": "uuid",
  "url": "http://<host>:<port>/sessions/<session_id>/master.m3u8"
}
```

The `<host>:<port>` is taken from the request's `Host` header. For a
`url` source the returned `url` is the original URL — FreeTube does
not proxy.

Errors:
- `400` — `source: ["url", ...]` with `sink: null`, or an unknown
  codec name.
- `404` — unknown device id.
- `502` — yt-dlp / fetch failure resolving streams.

#### `GET /sessions`

List all live sessions.

Response `200`:
```json
{
  "sessions": [
    {
      "session_id": "uuid",
      "created_at": 1779723395.62,
      "idle_seconds": 0.07,
      "sink": { "kind": "url", "friendly_name": null, "controllable": false }
    }
  ]
}
```

`sink.kind` is one of `"url" | "airplay" | "dlna"`. `controllable` is true
for `airplay`/`dlna` (they accept pause/resume/seek), false for `url`.

#### `GET /sessions/<id>`

Status of a single session. Same shape as one element of `GET /sessions`.
Returns `404` if unknown.

#### `DELETE /sessions/<id>`

Close the session, tear down producers and any attached cast sink.
Returns `204` on success, `404` if unknown.

#### `PUT /sessions/<id>/sink`

Attach (or replace) a sink for an existing source.

Request:
```json
{ "kind": "airplay", "device_id": "<id from /devices>" }
```
or
```json
{ "kind": "dlna", "device_id": "<id from /devices>" }
```
or
```json
{ "kind": "url" }
```

The previous sink (if any) is closed before the new one is installed.

#### `POST /sessions/<id>/{pause,resume,seek}`

Forward a control command to the session's sink. `seek` body:
```json
{ "position_seconds": 12.5 }
```
A `Url_consumer` sink rejects these with `400`.

### Streaming pipeline (HLS + DASH)

These are GET-only and meant for the consuming media player (ffmpeg,
AirPlay/DLNA renderer). All paths are also available under the legacy
`/session/<id>/...` prefix (singular) for back-compat.

```
GET /sessions/<id>/master.m3u8          HLS master playlist
GET /sessions/<id>/<rendition>/media.m3u8   HLS media playlist
GET /sessions/<id>/dash.mpd             DASH MPD manifest
GET /sessions/<id>/<rendition>/init.<ext>
GET /sessions/<id>/<rendition>/seg/<n>.<ext>
GET /sessions/<id>/storyboard/media.m3u8    HLS storyboard media playlist
GET /sessions/<id>/storyboard/<n>.jpg       Storyboard sprite sheet image
```

`<rendition>` is `video` or `audio`. `<ext>` is `mp4` for fMP4 producers
(`Vod_mp4`, `Webm_to_fmp4`).

The HLS master playlist includes an `#EXT-X-IMAGE-STREAM-INF` tag pointing
to `storyboard/media.m3u8` when storyboard data is available (VOD only).
The DASH MPD includes an image `AdaptationSet` with a `thumbnail_tile`
essential property. Players use the grid dimensions (`TILES` / tile value)
to crop individual thumbnails from the sprite sheet at seek time.

The device's `stream_format` setting (in its per-device config) determines
which manifest URL the sink receives: `master.m3u8` for HLS, `dash.mpd`
for DASH. Segment and init-segment routes are shared by both formats.

Every hit `touch`es the session, deferring GC.

### Devices

#### `GET /devices`

List discovered AirPlay + DLNA devices. Response is a flat list with a
`protocol` field. Each entry includes the derived `vendor`
(`"Apple"`, `"Samsung"`, `"Lg"`, `"Generic"`, or `null`) used to gate
advisory HLS tags for that destination.

#### `GET /devices/:id/config`

Return the per-device JSON override file, or `404` if no override
exists for this device. `:id` is the device id from `/devices`
(AirPlay `pairing_id` / DLNA `udn`).

#### `PUT /devices/:id/config`

Write a per-device JSON config. Body must include `id` (matching
the URL `:id`) and `friendly_name`. All other fields are optional.
Writes to `$XDG_CONFIG_HOME/freetube/devices/<slug(id)>.json`
where `slug` lowercases, rewrites Scandinavian characters
(æ→ae, ø→oe, å→aa) and replaces non `[a-z0-9_]` bytes with `_`.

```json
{
  "id": "ABCDEF123456",
  "friendly_name": "Living Room",
  "video_codecs": ["hevc", "avc"],
  "audio_codecs": ["aac"],
  "vendor": "Lg",
  "stream_format": "dash",
  "is_static": false,
  "kind": "airplay",
  "address": "10.0.0.42",
  "port": 7000,
  "control_url": null,
  "transcode": null
}
```

- `stream_format` — `"hls"` or `"dash"`. Controls which manifest format
  the server serves to this device. AirPlay devices default to `"hls"`,
  DLNA devices default to `"dash"`. The default is assigned at discovery
  time; change it here to override.

A static (`is_static: true`) entry is also seeded into the in-memory
discovery cache at startup and never pruned. Static entries support
remote clients on a different L2 segment that mDNS/SSDP can't reach.

#### `DELETE /devices/:id/config`

Remove the per-device JSON file (and revert to defaults).

### Legacy controls (filename-based casting)

These exist for back-compat with the original "pick a local file, play on
device" flow. They do **not** integrate with the source/sink session model.

```
POST /play     { "filename": "...", "device_id": "..." }
POST /pause    { "session_id": "..." }
POST /resume   { "session_id": "..." }
POST /seek     { "session_id": "...", "position_seconds": 12.5 }
POST /close    { "session_id": "..." }
```

The returned `session_id` from `/play` is a synthetic uuid backing the
cast sink only; there is no `Stream_source` behind it.

### Pairing

#### `POST /airplay/pair`

Two-step pairing for AirPlay devices that require a 4-digit PIN displayed
on screen.

Round 1 (request PIN):
```json
{ "device_id": "<id>" }
```
Response includes a `session_id` and instructs the device to display a PIN.

Round 2 (submit PIN):
```json
{ "device_id": "<id>", "session_id": "<from round 1>", "pin": "1234" }
```

### Static

```
GET  /static/<path>
HEAD /static/<path>
```
Serves files from `--static-root` (default `./static`). Used for the
fixture streams (`/static/sample/wildlife/streams.json`, etc.).
