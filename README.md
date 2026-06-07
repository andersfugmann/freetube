# FreeTube

A self-hosted YouTube streaming and casting service written in OCaml.
FreeTube fetches video from YouTube and serves it to AirPlay and DLNA devices
on the local network — either as a direct cast URL or repackaged on the fly as
HLS or DASH.

## Features

- Stream YouTube videos to AirPlay 2 and DLNA/UPnP renderers
- On-the-fly HLS and DASH repackaging (no transcoding required)
- Codec-aware stream selection (HEVC, AV1, VP9, AAC, Opus)
- Device discovery via mDNS (AirPlay) and SSDP (DLNA)
- HTTP API for browsing and controlling playback
- Browser extension for casting directly from YouTube
- Per-device configuration and vendor-specific quirk handling

## Install

Debian packages are published with each
[release](https://github.com/andersfugmann/freetube/releases):

```sh
sudo dpkg -i freetube_<version>_amd64.deb
sudo systemctl enable --now freetube
```

The browser extension is available as a separate package:

```sh
sudo dpkg -i freetube-plugin_<version>_all.deb
```

## Build

Requires OCaml 5.3+ via opam.

```sh
# Create a local switch and install dependencies
opam switch create . ocaml-base-compiler.5.4.1
eval $(opam env)
opam install . --deps-only --with-test

# Build
make build

# Run tests
make test

# Run the server
make run
```

## Configuration

Configuration is stored as JSON at `$XDG_CONFIG_HOME/freetube/config.json`
(typically `~/.config/freetube/config.json`, or `/etc/freetube/config.json`
when running via the systemd service).

Per-device overrides live in `$XDG_CONFIG_HOME/freetube/devices/<slug>.json`.

All fields are optional — missing values use the defaults shown below.
Configuration can be edited via the browser extension settings panel or the
`PUT /config` HTTP endpoint.

### Global configuration

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `listen_port` | int | `5544` | HTTP server listen port |
| `session_ttl_seconds` | float | `1800.0` | Idle session timeout before cleanup |
| `ntp_port` | int | `7010` | NTP timing port for AirPlay |
| `transcode` | bool | `false` | Master transcoding switch; when false, disables transcoding globally regardless of per-device settings |
| `gpu_device` | string\|null | `null` | VAAPI render node for hardware transcoding (e.g. `/dev/dri/renderD128`). When null, defaults to `/dev/dri/renderD128` |

### Streaming

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `streaming.prefetch_count` | int | `3` | Number of segments to prefetch ahead |
| `streaming.cache_capacity` | int | `6` | Max segments kept in memory cache |
| `streaming.segment_stale_threshold_seconds` | float | `10.0` | Seconds before a segment is considered stale |
| `streaming.live_window_seconds` | int | `10800` | Live stream DVR window (3 hours) |
| `streaming.default_segment_duration_us` | int | `5000000` | Default segment duration in microseconds |

### Network

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `network.max_connections_per_host` | int | `2` | Concurrent connections per upstream host |
| `network.max_redirects` | int | `5` | Maximum HTTP redirects to follow |
| `network.prefer_ip_version` | `"v4"`\|`"v6"` | `"v4"` | Preferred IP version for outbound connections |
| `network.file_chunk_size` | int | `65536` | Read chunk size for file I/O |
| `network.yt_dlp_force_ipv6` | bool | `true` | Force IPv6 when calling yt-dlp |

### Video

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `video.max_width` | int | `3840` | Maximum video width to select |
| `video.max_height` | int | `2160` | Maximum video height to select |

### Discovery

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `discovery.scan_timeout_seconds` | float | `5.0` | Device scan timeout |
| `discovery.airplay_interval_seconds` | float | `60.0` | AirPlay mDNS browse interval |
| `discovery.dlna_interval_seconds` | float | `60.0` | DLNA SSDP search interval |
