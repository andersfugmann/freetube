# FreeTube — Architecture

A high-level map of the code. For protocol details see `docs/protocols/`.

## One-line summary

FreeTube is a single-domain Eio server that fetches video from YouTube and
serves it to AirPlay / DLNA devices on the LAN either as a direct cast URL
or repackaged on the fly as an HLS or DASH stream.

## Layers

```
              ┌────────────────────────────────────────┐
              │                freetube                 │  process entrypoint +
              │  main.ml │ server.ml │ App.t │          │  HTTP dispatch (routes),
              │  *_handler.ml │ Sessions registry (GC)  │  static / streamed file
              │  Session.t = source + sink; Sink ADT    │
              └──────────────────┬──────────────────────┘
                                 │
                       ┌─────────▼─────────┐
                       │      devices      │  Discovery_{airplay,dlna},
                       │  Device, Vendor,  │  Device_store, Config_device,
                       │  Slug, …          │  Vendor classification
                       └────┬──────┬───┬───┘
                            │      │   │
            ┌───────────────▼─┐  ┌─▼───▼──┐   ┌───────────────┐
            │     airplay     │  │ stream │   │   youtube     │
            │  + Pairing      │  │        │   │   (yt-dlp +   │
            └─────────────────┘  │        │   │    Video_info)│
            ┌─────────────────┐  │        │   └───────┬───────┘
            │      dlna       │  │        │           │
            │  + Client/Mime  │  │        ◄───────────┘ codec
            └─────────────────┘  └────┬───┘ (leaf)
                                      │
                                      │   Stream.{Source, Producer,
                                      │   Hls, Dash, Selector,
                                      │   Bmff, Bmff_builder, Ebml,
                                      │   Vod_mp4, Vod_webm,
                                      │   Webm_to_fmp4,
                                      │   Byte_range_source,
                                      │   Http_range, ...}
                                      │
                                  ┌───▼───────────────┐
                                  │       util        │  Log_src, Uuid,
                                  │   (wrapped false) │  Local_ip,
                                  └───────────────────┘  Http_client
```

## Library map

| Library | Wrapped | Contents |
|---|---|---|
| `util` | no | `Log_src`, `Uuid`, `Local_ip`, `Http_client` (+ `Piaf_backend`) |
| `codec` | yes | Codec enum types (Video, Audio, Dynamic_range, …) — shared by `youtube` and `stream` |
| `youtube` | yes | `Video_info` parsing, `Fetcher` (yt-dlp / URL), `Cookies` |
| `airplay` | yes | AirPlay 2 protocol. Public: `Client` (opaque receiver description + getters + yojson), `Discovery` (`scan -> Client.t list`), `Session` (opaque; `connect ~client ~credentials ~ntp` + transport controls), `Credentials` (value + yojson + pair-setup conversions, **no I/O**), `Pairing` (pure handshake value, **no registry**), `Ntp_server` (opaque `t`, Eio-clock timing peer), `Error` (typed recoverable failures: `Network`/`Auth_failed`/`Command_rejected`/`Bad_response`). Internals (`Mdns`, `Pair_setup`, `Pair_verify`, `Rtsp`, `Playback`, crypto, …) unexposed. HTTP pairing envelopes live in `api` (`Api.Airplay_pairing`), not here |
| `dlna` | yes | DLNA discovery + playback. Public: `Client` (opaque renderer description + getters + yojson), `Discovery` (`scan -> Client.t list`), `Session` (opaque; `connect ~client` + transport controls), `Mime` (content-type taxonomy + `of_filename`), `Error` (typed recoverable failures: `Network`/`Action_failed`). Internals (`Ssdp`, `Device_description`, `Av_transport`, `Didl_lite` DIDL-Lite builder, SOAP) unexposed |
| `stream` | yes | Streaming pipeline (HLS + DASH): `Source`, `Producer` (with inline `Container`, `Segment`, `Segments`, `Segment_info`, `Meta`, `Error`, `Kind`), `Hls`, `Dash`, `Selector`, `Source_container`, `Bmff`, `Bmff_builder`, `Ebml`, `Codec_string`, `Vod_mp4`, `Vod_webm`, `Webm_to_fmp4`, `Byte_range_source`, `Http_range` |
| `devices` | yes | Cast-target discovery + modelling: `Discovery_airplay`, `Discovery_dlna`, `Device`, `Device_store`, `Config_device`, `Vendor`, `Slug` |
| `freetube` | yes (+ thin `main` exe) | Routes, handlers (`Playback_handler`, `Sessions_handler`, `Airplay_handler`, `Devices_handler`, `Static`), middleware, `App.t` (holds the running `Airplay.Ntp_server.t`), `Config_global`, `Session` (single-session record: source + sink) + `Sink` (URL/AirPlay/DLNA target ADT), `Sessions` registry (GC), `Airplay_credentials` (XDG-backed credential persistence) + `Airplay_pairing` (in-flight pair-setup registry); `main.ml` entrypoint |
| `bin/` | n/a | `freetube_client` — consolidated CLI with subcommands `devices`, `stream`, `sessions`, `airplay_pair`, `play_file` (cmdliner-based) |

## Session model

FreeTube has a single session concept, `Session.t`, that pairs a
*source* (HLS pipeline state) with a *sink* (where the bytes go):

```ocaml
type t = {
  id              : string;
  created_at      : float;
  last_accessed_at: float;
  source          : Stream.Source.t option;
  sink            : Sink.t;
}
```

`source` is optional: `POST /sessions` with `source: ["url", ...]`
creates a session that has no FreeTube producer — the sink plays the
external URL directly, and the HLS pipeline routes
(`/sessions/<id>/master.m3u8` and friends) return `409 Conflict`.

The sink ADT (`Sink.t`) has three variants:

1. **`Url_consumer`** — the caller pulls `master.m3u8` over HTTP itself.
   No outbound state. `pause`/`resume`/`seek` are rejected.
2. **`Airplay { device; session }`** — bytes are pushed to a discovered
   AirPlay device via the AirPlay-2 control channel.
3. **`Dlna { friendly_name; control_url; title; mime; session }`** — bytes
   are pushed to a DLNA `MediaRenderer` via SOAP.

A session's sink can be swapped at runtime (`PUT /sessions/<id>/sink`):
the old sink is closed, then the new one is installed. The source is
unaffected.

The `source` is a `Stream.Source.t` — pure pipeline
state: a `Http_client.t` plus one `Producer.t` per rendition
(video, audio). It owns no identity or timestamps; identity and idle
tracking live on `Session.t`.

`Stream_source` is built from a `Youtube.t`, which carries the parsed
`Video_info.t` plus a `Youtube.Fetcher.t` — a thunk
(`unit -> Yojson.Safe.t`) that produces fresh streams JSON on demand.
Two fetchers exist today:
- `Youtube.Fetcher.of_yt_dlp` — shells out to `yt-dlp -j VIDEO_ID`
  (used when `POST /sessions` is called with
  `source: ["youtube_id", id]`).
- `Youtube.Fetcher.of_url` — fetches a pre-recorded yt-dlp-shaped JSON
  over HTTP (used when `POST /sessions` is called with
  `source: ["youtube_file", url]`, e.g. the wildlife sample fixture).

`Youtube.refresh` re-invokes the same fetcher when a stream URL has
gone stale, so both code paths share the refresh logic.

All sessions live in one registry, `Sessions`
(`Session.t list ref`), regardless of sink kind.

### Lifecycle: idle GC

`Sessions` runs an idle sweep
(`start_gc ~ttl:60.0 ~interval:10.0`) on its own fiber. Every HTTP hit
to `/sessions/<id>/...` goes through `with_session`, which calls
`Session.touch` to bump a monotonic `last_accessed_at`.
The sweep partitions the list into keep/close, replaces the registry
ref, *then* closes each evicted session — the
partition-then-replace-ref-then-close order required for safe mutation
under single-domain Eio. `Session.close` first closes the sink and then
tears down both producers (`Stream_source.close`); both close paths are
exception-swallowing so one stuck pipeline cannot abort the sweep.

## Producer / consumer split

The HLS pipeline is built on a small `Producer.S` interface
(`src/producer/producer.ml`):

```ocaml
module type S = sig
  type t
  val init_segment   : t -> rendition -> bytes
  val fetch_segment  : t -> rendition -> int -> bytes
  …
end
```

Producers raise `Producer.Error.E` for unrecoverable failures (parse,
codec-unsupported, source-unavailable); the HTTP handler catches this and
maps to a status code (`Playback_handler.producer_status`). `Result.t`
is used only where the caller can actually act on the error — e.g.
`Http_range.fetch` returns a result so segment fetching can retry.

Concrete producers live in `stream_producer`:

- `Vod_mp4` — repackages a YouTube fragmented MP4 (mp4_dash / m4a_dash)
  into HLS-friendly fMP4 segments. Source bytes pass through verbatim.
- `Vod_webm` — fetches a YouTube WebM (webm_dash) source, returning
  cluster-aligned byte ranges over HTTP range requests.
- `Webm_to_fmp4` — wraps `Vod_webm` and **remuxes** each WebM cluster
  into an fMP4 `moof`+`mdat` fragment (no transcode). Reports
  `Producer.Container.Mp4` so HLS, AirPlay and ffmpeg's strict segment
  whitelist all accept the output. Codec config boxes (`av1C`, `vpcC`,
  `dOps`) are synthesised from the WebM CodecPrivate and Colour
  elements.
- `Byte_range_source` — shared HTTP byte-range fetcher used by the MP4
  and WebM sources.

`Playback.Source_container` is the typed view consumed by
`Hls_session` to pick the right producer for a given
`Youtube.Video_info.Stream.t`:

```
Mp4_dash  → Vod_mp4
M4a_dash  → Vod_mp4
Webm_dash → Vod_webm wrapped by Webm_to_fmp4
```

Consumers (`Hls`, `Hls_session`) only see the `Producer.S`
interface; the source format is hidden.

## Configuration

Two JSON files under `$XDG_CONFIG_HOME/freetube/`:

- `config.json` — global runtime settings (listen port, session TTL,
  GC interval, discovery intervals, NTP port, transcode flag). All
  fields optional; defaults baked in. Loaded once at startup; no live
  reload. Parse errors cause the file to be deleted and defaults used.

- `devices/<slug(id)>.json` — per-device override keyed by the device
  `id` (AirPlay `pairing_id` / DLNA `udn`). Fields: `id` (required),
  `friendly_name` (required), `video_codecs`, `audio_codecs`, `vendor`
  (`Apple` / `Samsung` / `Lg` / `Generic` — pins the HLS gating profile
  when discovery heuristics get it wrong), `stream_format` (`hls` or
  `dash` — controls which manifest format the sink receives; AirPlay
  devices default to `hls`, DLNA to `dash`), `is_static`, `address`,
  `port`, `kind`, `control_url`, `transcode`. Loaded at startup; bad
  files are logged and skipped. Written via
  `PUT /devices/<id>/config`. Merged into the matching discovery entry
  by `id` at scan time; static entries (`is_static = true`) are seeded
  straight into the cache with `last_seen = Float.infinity` so they
  survive pruning. Keying on `id` (not `friendly_name`) means two
  devices sharing a friendly name (e.g. an AirPlay and a DLNA
  endpoint on the same TV) have independent config.

The major-brand override (`iso5` → `isom`) is applied unconditionally
in the producer pipeline by `Stream.Brand_override.wrap_{video,audio}`,
not at the HTTP boundary. Every fMP4 init segment is rewritten before
it leaves the producer; segments without a leading `ftyp`/`styp` (the
WebM-remux moof+mdat pattern) pass through untouched.

## Discovery

`freetube_discovery` runs two parallel caches:

- `Devices.Discovery_airplay` — caches/enriches the `Airplay.Discovery`
  mDNS scan for `_airplay._tcp`. Each cache entry stores the opaque
  `Airplay.Client.t` verbatim (persisted via its yojson) plus freetube
  enrichment (codecs, vendor, last_seen, is_static); `Devices_handler`
  projects it into the flat `Api.Device.airplay` wire DTO via the `Client`
  getters.
- `Devices.Discovery_dlna` — caches/enriches the `Dlna.Discovery`
  SSDP M-SEARCH for `urn:schemas-upnp-org:device:MediaRenderer:1`. Each cache
  entry stores the opaque `Dlna.Client.t` verbatim (persisted via its yojson)
  plus freetube enrichment; `Devices_handler` projects it into the flat
  `Api.Device.dlna` wire DTO via the `Client` getters.

The raw LAN scan lives in the standalone client libs (`Airplay.Discovery`,
`Dlna.Discovery`); `devices` only adds freetube policy on top.

Both publish into an `Atomic.t`-backed cache with TTL pruning and a
JSON-file backing store. The HTTP `/devices` handler merges both.

### Server advertisement

`Freetube.Mdns_advertise` runs a minimal mDNS responder that advertises
the hostname `freetube.local` as an A record pointing to the server's LAN
IP. This allows clients (browser extension, CLI) to reach the server at
`http://freetube.local:5544` without manual IP configuration. The responder
binds to UDP 5353, joins the 224.0.0.251 multicast group, and replies to
A/ANY queries for `freetube.local` with a 120 s TTL.

## HTTP layer

`Freetube.Server` builds method-specific routers (POST, GET, PUT,
DELETE, HEAD) using the `routes` library and dispatches to handlers in
`*_handler.ml`. All server-scoped singletons (env, sw, port, caches,
sessions) are bundled into `Freetube.App.t` and threaded as `~app`.
Handlers read only the fields they need.

The HTTP surface is documented in [`API.md`](./API.md). At a glance:

- `POST /sessions` — create a session from a `youtube_id` or fixture
  `url`.
- `GET /sessions`, `GET /sessions/<id>`, `DELETE /sessions/<id>` — list,
  inspect, close.
- `PUT /sessions/<id>/sink` — swap the sink (URL → AirPlay/DLNA).
- `POST /sessions/<id>/{pause,resume,seek}` — control a cast sink.
- `GET /sessions/<id>/master.m3u8` (+ media / init / segment) — the HLS
  pipeline output. Also exposed under legacy `/session/<id>/...`
  (singular) for back-compat.
- `GET /devices` — merged AirPlay + DLNA discovery cache.
- `GET`/`PUT`/`DELETE /devices/<id>/config` — per-device JSON override
  (codec preferences, vendor pin, static-client bootstrap).
- Legacy filename-cast endpoints (`/play`, `/pause`, `/resume`, `/seek`,
  `/close`) are preserved.

## Manifest format selection

Each device carries a `stream_format` setting (`Hls` or `Dash`) that
determines which manifest is served to its renderer:

- **HLS** (`master.m3u8` + per-rendition `media.m3u8`) — used by AirPlay
  devices (default) and any device explicitly configured for HLS.
- **DASH** (`dash.mpd` — a single MPD covering both renditions) — used by
  DLNA devices (default) and any device explicitly configured for DASH.

The format is assigned at device discovery time (AirPlay → HLS, DLNA →
DASH) and persisted in the per-device config. It can be changed via
`PUT /devices/<id>/config` or the browser plugin's device settings UI.

Both formats share the same fMP4 segments and init segments; only the
manifest generation differs. The `Stream.Source` module exposes both
`master`/`media` (HLS) and `dash_mpd` (DASH) functions over the same
underlying producers.

## HLS profile gating

`Session.Vendor.t = Apple | Samsung | Lg | Generic` classifies a sink's
destination device. It is derived once at discovery time from the
AirPlay TXT `manufacturer` key (omitted on Apple's own devices, which
are identified by their `AppleTV*`/`HomePod*`/`iPhone*`/etc. `model`)
or the DLNA description's `manufacturer`. The chosen vendor is logged
once per device and persisted in the discovery cache. A per-device
config can pin the vendor manually.

`Hls.profile` is a record of four advisory-tag flags
(`independent_segments`, `playlist_type`, `session_data`,
`start_offset`). `playback_handler.profile_of_vendor` maps the
attached sink's vendor to a profile; sessions with no sink fall back
to `Generic` (everything on). Codec selection is never gated by
vendor — the device's advertised codec list is used as-is, overridable
by the request. DASH manifests do not use profile gating — they follow
the standardized MPEG-DASH `isoff-on-demand` profile.

## Concurrency model

- Single Eio domain.
- One fiber per request.
- Shared mutable state (e.g. `Sessions`) is protected by the convention
  that every read-modify-write happens in a flow with no scheduling
  points: compute the new value, assign the `ref`, then perform any
  I/O on the local snapshot.

## Cross-cutting helpers

- `uuid` — `Uuid.v4`, `Uuid.v4_uppercase`.
- `local_ip` — `Local_ip.for_peer`, `Local_ip.for_address`.
- `freetube_http.Json_io` — JSON request/response helpers.
- `freetube_http.Streamed_file` — file-fd-lifetime helper for static.
- `airplay.Identity` — masquerade-as-iPhone constants (one place to
  change if Apple ever rejects them).
- `log_src` — per-module `Logs.Src.t` registration.

## What is NOT here

- No persistent database. State is in-memory refs/atomics with optional
  JSON snapshots for device caches.
- No config file. All values are either constants in code or taken from
  Eio's stdenv / CLI args.
- No worker pool. Everything runs on the Eio default scheduler.
