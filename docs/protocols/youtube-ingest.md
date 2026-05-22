# YouTube Ingest Protocol Reference

Reference for the YouTube ingest subset used by FreeTube: `yt-dlp` extraction, stream metadata consumed by the server, and the behavior of returned CDN URLs for VOD and live playback.

Scope: `yt-dlp` invocation, JSON fields, codec/container availability, VOD byte-range URLs, live `http_dash_segments` fragments, live metadata, cookies, PO-token gating, IP-version tradeoffs, and failure classification.

## Status labels

| Label | Meaning |
|---|---|
| Spec | Defined by `yt-dlp`, HTTP, Netscape cookies, ISO BMFF, WebM/Matroska, or DASH/HLS conventions. |
| Empirically observed (FreeTube) | Behavior observed against YouTube and encoded in this repository. Not asserted as a public YouTube contract. |
| Current FreeTube | Behavior in `src/youtube/*` and session code at this revision. |

## 1. yt-dlp invocation contract

Current FreeTube invokes `yt-dlp` as a direct subprocess. Arguments are passed as an argv vector, not through a shell. The video id is placed after `--`.

### 1.1 Command shape

Without cookies:

```sh
yt-dlp --remote-components ejs:github --extractor-args youtube:formats=incomplete --js-runtimes deno:<path> -j -- <video_id>
```

With cookies:

```sh
yt-dlp --remote-components ejs:github --extractor-args youtube:formats=incomplete --js-runtimes deno:<path> --cookies <netscape_cookie_file> -j -- <video_id>
```

| Item | Value |
|---|---|
| Executable | Configured `yt_dlp_path` |
| Positional input | `<video_id>` after literal `--` |
| Child stdout | JSON output only; FreeTube parses it as one `yt-dlp` JSON object |
| Child stderr | Diagnostics and extractor errors; preserved on non-zero exit |
| Timeout | Configured `timeout_secs` |
| Isolation | Inherits process/container/systemd hardening from the FreeTube process |

### 1.2 Required flags

| Flag | Status | Semantics |
|---|---|---|
| `--remote-components ejs:github` | Current FreeTube | Pulls EJS extractor components from GitHub. |
| `--extractor-args youtube:formats=incomplete` | Current FreeTube | Required to expose adaptive formats that may otherwise be omitted. |
| `--js-runtimes deno:<path>` | Current FreeTube when configured | Lets `yt-dlp` run YouTube signature-decryption JavaScript with Deno. |
| `-j` | Spec / Current FreeTube | Emit JSON to stdout, one JSON object per video. |
| `--cookies <netscape_cookie_file>` | Spec / Current FreeTube when cookies are present | Supplies authenticated YouTube cookies. |
| `--` | Current FreeTube | Terminates option parsing before `<video_id>`. |

### 1.3 Stdout, stderr, exit codes

| Channel / result | Contract |
|---|---|
| `stdout` on success | One JSON object for the requested video. FreeTube expects valid UTF-8 JSON. |
| `stderr` on success | May contain warnings. FreeTube does not parse it. |
| Exit status `0` | Extraction succeeded; JSON is parsed from `stdout`. |
| Non-zero exit | Extraction failed; FreeTube reports `yt-dlp exited with <status>: <stderr>`. |
| Spawn failure | Reported as `yt-dlp not found at '<path>': <io-error>`. |
| Timeout | Reported as `yt-dlp timed out after <seconds>s`. |
| Invalid JSON | Reported as `Failed to parse yt-dlp JSON: <serde-error>`. |

Current FreeTube does not branch on individual `yt-dlp` exit-code numbers. The OS status and stderr text are carried into the extraction error.

### 1.4 Cookie jar format

`--cookies` expects a Netscape `cookies.txt` file.

| Line type | Form |
|---|---|
| Comment | `# ...` |
| HttpOnly comment prefix | `#HttpOnly_<domain>\t...` |
| Cookie row | Seven tab-separated fields |

Cookie row fields:

| Field | Name | Example | Meaning |
|---:|---|---|---|
| 1 | domain | `.youtube.com` | Cookie domain. Leading dot means subdomains. |
| 2 | include subdomains | `TRUE` | Whether subdomains match. |
| 3 | path | `/` | Cookie path. |
| 4 | secure | `TRUE` | Send only over HTTPS. |
| 5 | expires | `1735000000` | Unix seconds, or `0` for session-style entries. |
| 6 | name | `SAPISID` | Cookie name. |
| 7 | value | `<opaque>` | Cookie value. |

Current FreeTube can also construct this file shape in memory from API-supplied cookie entries and pass it to `yt-dlp` through `/proc/self/fd/<fd>`.

## 2. yt-dlp JSON schema subset consumed by FreeTube

Current FreeTube reads a small subset of `yt-dlp`'s full JSON object. Unknown fields are ignored.

### 2.1 Top-level fields

| JSON field | Type | Required by FreeTube | Default if missing | FreeTube field |
|---|---|---:|---|---|
| `id` | string | Yes | none | `VideoDetail.id` |
| `title` | string | No | `""` | `title` |
| `description` | string | No | `""` | `description` |
| `channel` | string | No | `""` | `channel_name` |
| `duration` | number seconds | No | `0` | `duration_secs` |
| `view_count` | integer | No | `0` | `view_count` |
| `thumbnail` | string URL | No | `""` | `thumbnail_url` |
| `is_live` | boolean | No | `false` | `is_live` |
| `formats` | array | No | empty | filtered into `adaptive_formats` |

### 2.2 Per-format fields

| JSON field | Type | Meaning |
|---|---|---|
| `format_id` | string | YouTube itag or yt-dlp format identifier. |
| `url` | string | VOD CDN URL, live MPD URL, or HLS playlist URL. Empty formats are ignored. |
| `ext` | string | Container hint: `mp4`, `webm`, or HLS-related extension. Defaults to `mp4` if missing. |
| `vcodec` | string | Video codec. `"none"` means no video. |
| `acodec` | string | Audio codec. `"none"` means no audio. |
| `width` | integer | Encoded video width. |
| `height` | integer | Encoded video height. |
| `fps` | number | Frame rate. Stored as integer fps. |
| `tbr` | number kb/s | Total bitrate. Preferred bitrate source. |
| `vbr` | number kb/s | Video bitrate fallback. |
| `abr` | number kb/s | Audio bitrate fallback and audio-quality classifier input. |
| `asr` | integer Hz | Audio sample rate. |
| `audio_channels` | integer | Audio channel count. |
| `format_note` | string | Quality label / note. |
| `dynamic_range` | string | `SDR`, `HDR10`, `HDR10+`, `HDR12`, `HLG`, `DV`, or absent. |
| `protocol` | string | `https`, `http_dash_segments`, `m3u8_native`, `m3u8`, or unsupported. |
| `fragment_base_url` | string | Live DASH segment base URL. Required for accepted `http_dash_segments`. |
| `fragments[].path` | string | Live fragment path appended to `fragment_base_url`. |
| `fragments[].duration` | number seconds | Live fragment duration estimate. |

### 2.3 Accepted protocol classification

| `protocol` | Accepted when | Shape |
|---|---|---|
| `https` | VOD only, video-only or audio-only | Monolithic adaptive file, fetched by HTTP byte range. |
| `http_dash_segments` | Live only, video-only or audio-only, with `fragment_base_url` and `fragments[]` | Path-based DASH live fragments. |
| `m3u8_native` / `m3u8` | VOD or live, muxed video+audio only | HLS playlist, YouTube muxed fallback. |
| Other values (`http`, `mhtml`, ...) | Never | Dropped at ingest. |

Empirically observed (FreeTube): YouTube live `https` variants may appear in extraction results but 404 on `GET`; Current FreeTube rejects `https` when `is_live == true` and uses `http_dash_segments` instead.

### 2.4 Representative VOD JSON sample

```json
{
  "id": "ucZl6vQ_8Uo",
  "title": "Example video",
  "description": "Example description",
  "channel": "Example channel",
  "duration": 123.0,
  "view_count": 1000,
  "thumbnail": "https://i.ytimg.com/vi/ucZl6vQ_8Uo/hqdefault.jpg",
  "is_live": false,
  "formats": [
    {
      "format_id": "401",
      "url": "https://rr1---sn-example.googlevideo.com/videoplayback?...&itag=401&clen=123456789&expire=1735000000",
      "ext": "mp4",
      "vcodec": "av01.0.12M.10",
      "acodec": "none",
      "width": 3840,
      "height": 2160,
      "fps": 60.0,
      "tbr": 18000.0,
      "vbr": 18000.0,
      "format_note": "2160p",
      "dynamic_range": "HDR10",
      "protocol": "https"
    },
    {
      "format_id": "251",
      "url": "https://rr1---sn-example.googlevideo.com/videoplayback?...&itag=251&clen=7654321&expire=1735000000",
      "ext": "webm",
      "vcodec": "none",
      "acodec": "opus",
      "abr": 160.0,
      "asr": 48000,
      "audio_channels": 2,
      "protocol": "https"
    },
    {
      "format_id": "96",
      "url": "https://manifest.googlevideo.com/api/manifest/hls_variant/.../playlist/index.m3u8",
      "ext": "mp4",
      "vcodec": "avc1.640028",
      "acodec": "mp4a.40.2",
      "width": 1920,
      "height": 1080,
      "fps": 30.0,
      "tbr": 4500.0,
      "protocol": "m3u8_native"
    }
  ]
}
```

### 2.5 Representative live JSON sample

```json
{
  "id": "live_video_id",
  "title": "Example live stream",
  "is_live": true,
  "formats": [
    {
      "format_id": "303-dash",
      "url": "https://manifest.googlevideo.com/api/manifest/dash/...",
      "fragment_base_url": "https://rr1---sn-example.googlevideo.com/videoplayback/id/source/yt_live_broadcast/.../",
      "fragments": [
        { "path": "sq/1220252/lmt/162", "duration": 5.0 },
        { "path": "sq/1220253/lmt/162", "duration": 5.0 }
      ],
      "ext": "webm",
      "vcodec": "vp09.00.51.08",
      "acodec": "none",
      "width": 1920,
      "height": 1080,
      "fps": 30.0,
      "tbr": 4500.0,
      "protocol": "http_dash_segments"
    },
    {
      "format_id": "251-dash",
      "url": "https://manifest.googlevideo.com/api/manifest/dash/...",
      "fragment_base_url": "https://rr1---sn-example.googlevideo.com/videoplayback/id/source/yt_live_broadcast/.../",
      "fragments": [
        { "path": "sq/1220252/lmt/162", "duration": 5.0 }
      ],
      "ext": "webm",
      "vcodec": "none",
      "acodec": "opus",
      "abr": 160.0,
      "asr": 48000,
      "audio_channels": 2,
      "protocol": "http_dash_segments"
    }
  ]
}
```

## 3. Container / codec matrix YouTube serves

| Source shape | Container | `protocol` | Video codecs | Audio codecs | Notes |
|---|---|---|---|---|---|
| VOD adaptive video | MP4 / fMP4 | `https` | AV1 (`av01.*`), HEVC (`hev1.*` / `hvc1.*`), H.264 (`avc1.*`) | none | Monolithic file. HEVC is PO-token gated in default extraction. |
| VOD adaptive audio | MP4 / fMP4 | `https` | none | AAC-LC (`mp4a.40.2`) | Monolithic file. |
| VOD adaptive video | WebM | `https` | VP9 (`vp09.*`), VP9.2 HDR (`vp09.02.*` with HDR dynamic range) | none | Monolithic file with WebM Cues. |
| VOD adaptive audio | WebM | `https` | none | Opus (`opus`) | Monolithic file with WebM Cues. |
| VOD or live muxed HLS | MPEG-TS | `m3u8_native` / `m3u8` | H.264 (`avc1.*`) | AAC-LC (`mp4a.40.2`) | Muxed fallback. Segments are playlist-listed TS chunks. |
| Live DASH fragments | MP4 / fMP4 | `http_dash_segments` | H.264 (`avc1.*`) | AAC-LC (`mp4a.40.2`) | Separate video-only and audio-only fragment streams. |
| Live DASH fragments | WebM | `http_dash_segments` | VP9 (`vp09.*`) | Opus (`opus`) | Separate video-only and audio-only fragment streams. |

Empirically observed (FreeTube): live extraction exposes only WebM VP9/Opus and MP4 H.264/AAC families in the `http_dash_segments` path. AV1 and HEVC are not part of the live ingest matrix currently used by FreeTube.

Empirically observed (FreeTube): HEVC (`hev1` / `hvc1`) is unavailable in default `yt-dlp` extraction without a YouTube PO token. Current FreeTube treats HEVC primarily as an output/transcode target or a passthrough source only when extraction actually returns it.

## 4. VOD URL semantics (`protocol="https"`)

### 4.1 Resource model

| Property | Value |
|---|---|
| Host | `*.googlevideo.com` |
| Path | Usually `/videoplayback` |
| Query | Signed, expiring parameters; commonly includes `itag`, `expire`, `clen`, codec/client parameters, and signatures |
| Body | One monolithic video-only or audio-only file |
| Addressing | HTTP `Range` header or `range=<start>-<end>` query parameter |
| Expiry behavior | Expired/superseded URL returns 403; rerun `yt-dlp` to refresh |

The CDN URL is not a per-segment URL. FreeTube derives byte ranges from MP4 SIDX or WebM Cues, then fetches the required bytes from this monolithic object.

### 4.2 Range header request

```http
GET /videoplayback?expire=1735000000&itag=401&clen=123456789&... HTTP/2
Host: rr1---sn-example.googlevideo.com
Range: bytes=0-524287
User-Agent: freetube
Accept: */*
```

Typical response:

```http
HTTP/2 206 Partial Content
Content-Type: video/mp4
Accept-Ranges: bytes
Content-Range: bytes 0-524287/123456789
Content-Length: 524288
```

### 4.3 `range=` query alternative

YouTube also accepts a query-parameter byte range on many `videoplayback` URLs.

```http
GET /videoplayback?expire=1735000000&itag=401&clen=123456789&range=0-524287&... HTTP/2
Host: rr1---sn-example.googlevideo.com
User-Agent: freetube
Accept: */*
```

Typical response:

```http
HTTP/2 206 Partial Content
Content-Type: video/mp4
Content-Range: bytes 0-524287/123456789
Content-Length: 524288
```

Current FreeTube's segmented VOD pipeline is range-oriented: `/init` and `/seg/<n>` map to upstream byte ranges, and stale URLs are refreshed by invoking `yt-dlp` again for the same video id.

## 5. Live URL semantics (`protocol="http_dash_segments"`)

### 5.1 yt-dlp fields

| Field | Meaning |
|---|---|
| `url` | DASH MPD URL from `yt-dlp`; not the fragment URL FreeTube fetches. |
| `fragment_base_url` | CDN base URL for path-based live fragments. Must be non-empty. |
| `fragments[]` | Replay-window fragment list. Each entry carries `path` and `duration`. |
| `fragments[].path` | Appended to `fragment_base_url` without additional escaping. |
| `fragments[].duration` | Initial duration estimate in seconds. In-band metadata may override it. |

Accepted live fragment URL syntax:

```text
<fragment_base_url>sq/<seq>/lmt/<lmt>
```

Empirically observed (FreeTube): the path shape is `sq/<seq>/lmt/<lmt>`. `sq` is the live segment sequence number. `lmt` is also reported in the `X-Segment-Lmt` response header and is propagated in refreshed live URLs.

### 5.2 Fragment request example

```http
GET /videoplayback/id/source/yt_live_broadcast/.../sq/1220252/lmt/162 HTTP/2
Host: rr1---sn-example.googlevideo.com
User-Agent: freetube
Accept: */*
```

Typical WebM response:

```http
HTTP/2 200 OK
Content-Type: video/webm
Content-Length: 843210
X-Sequence-Num: 1220252
X-Head-Seqnum: 1220260
X-Head-Time-Millis: 6096498674
X-Segment-Lmt: 162
```

Typical MP4 response:

```http
HTTP/2 200 OK
Content-Type: video/mp4
Content-Length: 912345
X-Sequence-Num: 1222775
X-Head-Seqnum: 1222783
X-Head-Time-Millis: 6098123456
X-Segment-Lmt: 167
```

Each live response is a fused blob for one fragment. For MP4, the blob may contain file metadata and fragment boxes in one response. For WebM, the blob may contain a self-contained WebM segment with EBML/Segment structure.

## 6. Live response headers

Empirically observed (FreeTube): YouTube live fragment responses include YouTube-specific headers parsed by `src/youtube/live_meta.rs`.

| Header | Value type | Meaning |
|---|---|---|
| `X-Sequence-Num` | unsigned decimal integer | Sequence number for this fragment. |
| `X-Head-Seqnum` | unsigned decimal integer | Live-edge sequence number reported by the CDN. |
| `X-Head-Time-Millis` | unsigned decimal integer | Broadcast-relative head time in milliseconds. |
| `X-Segment-Lmt` | unsigned decimal integer | Segment `lmt` value. Used when refreshing path-style live URLs. |

Missing or malformed values are treated as absent. Header parsing does not fail the segment by itself.

## 7. Live in-band metadata

Empirically observed (FreeTube): YouTube live fragments carry per-segment metadata in-band. The metadata confirms sequence number and provides duration/timeline fields not present in response headers.

### 7.1 Shared metadata payload

The payload is text lines in `Key: Value` form, typically CRLF-terminated.

```text
Sequence-Number: 1220252
Target-Duration-Us: 5000000
First-Frame-Time-Us: 1779385497627050
```

| Key | Type | Meaning |
|---|---|---|
| `Sequence-Number` | unsigned decimal integer | Fragment sequence number. Should agree with `X-Sequence-Num`. |
| `Target-Duration-Us` | unsigned decimal integer | Authoritative fragment duration in microseconds. |
| `First-Frame-Time-Us` | unsigned decimal integer | Unix-epoch microsecond timestamp for the first frame. |

Unknown keys are ignored.

### 7.2 WebM carriage

Empirically observed (FreeTube): WebM live fragments carry metadata under this element path:

```text
Segment -> Tags -> Tag -> SimpleTag
```

| Element | Identifier | Required field |
|---|---:|---|
| `Tags` | `0x1254C367` | Container for tags. |
| `Tag` | `0x7373` | One tag entry. |
| `SimpleTag` | `0x67C8` | Metadata tag. |
| `TagName` | `0x45A3` | Must start with `http://youtube.com/streaming/metadata/segment/`. |
| `TagString` | `0x4487` | Contains the `Key: Value` payload. |

### 7.3 MP4 carriage

Empirically observed (FreeTube): MP4 live fragments carry metadata in an `emsg` v0 box. The `scheme_id_uri` prefix matches WebM `TagName`:

```text
http://youtube.com/streaming/metadata/segment/
```

`emsg` v0 body fields relevant to matching:

| Field | Requirement |
|---|---|
| `version` | `0` |
| `scheme_id_uri` | Null-terminated UTF-8 string starting with `http://youtube.com/streaming/metadata/segment/` |
| `value` | Ignored |
| `timescale` / `presentation_time_delta` / `event_duration` / `id` | Ignored by FreeTube metadata extraction |
| `message_data` | UTF-8 `Key: Value` payload |

## 8. Cookies and authentication

Use `yt-dlp --cookies-from-browser` to export a Netscape cookie jar from a browser profile, then pass it back with `--cookies` during extraction.

```sh
yt-dlp --cookies-from-browser chromium --cookies cookies.txt --skip-download -- <video_id>
```

| Item | Contract |
|---|---|
| Export format | Netscape `cookies.txt` |
| Ingest flag | `--cookies <netscape_cookie_file>` |
| Auth scope | Whatever the exported browser cookies authorize for YouTube. |
| Common need | Age-gated, members-only, region/account-gated, or bot-challenged videos. |

Empirically observed (FreeTube): without cookies, YouTube may fail extraction with `Sign in to confirm you're not a bot`. This is an external YouTube authentication/bot-detection condition, not a stream-selection bug.

## 9. PO Token / HEVC gating

Empirically observed (FreeTube): YouTube HEVC formats are PO-token gated. With the current default invocation, `yt-dlp` normally returns no HEVC adaptive formats even for videos where YouTube has HEVC encodes.

| Consequence | Current FreeTube behavior |
|---|---|
| HEVC absent from `formats[]` | Resolver treats HEVC source as unavailable. |
| Device supports HEVC | HEVC may still be used as an output target if transcoding is enabled. |
| Test matrix requests HEVC source | Missing source family is a skip/absence condition, not a code failure. |
| PO-token support changes later | Revisit ingest invocation and codec-selection assumptions. |

Current FreeTube does not synthesize source HEVC. It only uses streams that `yt-dlp` actually returns.

## 10. IP-version and bot-detection tradeoffs

Current FreeTube has the `yt-dlp` `-4` flag disabled.

| Flag | Meaning | Current status |
|---|---|---|
| `-4` | Force IPv4 for `yt-dlp` network access. | Disabled. |

Empirically observed (FreeTube): forcing IPv4 currently increases YouTube bot-detection failures in this deployment. The code comment says to re-enable `-4` only when IPv4 bot detection is resolved.

Operational implication: changing IP-version behavior can change extraction success independently of FreeTube's parsing, resolver, or streaming pipeline.

## 11. Failure modes summary

### 11.1 Transient or external failures

Do not change FreeTube code solely in response to these without independent evidence of a code regression.

| Failure | Observable signal | Action |
|---|---|---|
| URL expiry | CDN `403 Forbidden` for a previously working `*.googlevideo.com` URL | Refresh by rerunning `yt-dlp`; Current FreeTube does this on stale URL paths. |
| YouTube bot challenge | `yt-dlp` stderr includes `Sign in to confirm you're not a bot`; CDN may return `429` | Supply fresh cookies, wait out rate limiting, or change network/IP conditions. |
| Missing auth cookies | Extraction fails for account-gated content | Export cookies with `--cookies-from-browser` and retry with `--cookies`. |
| Network failure | DNS, connection timeout/refused, TLS failure | Retry after network recovery. |
| `yt-dlp` timeout | `yt-dlp timed out after <seconds>s` | Retry; increase configured timeout only if consistently too low. |
| Expired cookies | `yt-dlp` auth failure after previously working extraction | Re-export cookies. |
| Live head moved | Requested `sq/<seq>` no longer available or head headers advanced | Refresh live fragment list / retry near current head. |
| HEVC absent because no PO token | No `hev1` / `hvc1` formats in JSON | Treat as unavailable source; do not change resolver logic. |

### 11.2 Permanent input/configuration failures

| Failure | Observable signal | Action |
|---|---|---|
| `yt-dlp` missing | `yt-dlp not found at '<path>'` | Fix `yt_dlp_path` or installation. |
| Deno missing or incompatible | `yt-dlp` signature-decryption error mentioning JS runtime | Fix `--js-runtimes deno:<path>` configuration. |
| Unsupported `protocol` only | Formats exist but all are `http`, `mhtml`, or other unsupported protocols | Not ingestible by Current FreeTube. |
| No accepted adaptive formats | `No adaptive formats available for <id>` | Video cannot be served by current ingest rules. |
| Requested itag absent | `Format id '<id>' not found among available streams` | Choose an itag present in `formats[]`. |
| Unsupported codec combination | No matching video/audio stream or unsupported transcode pair | Change device/request capabilities or enable a supported transcode path. |
| Malformed `yt-dlp` JSON | JSON parse error | Update/fix `yt-dlp` or inspect extractor output. |

## 12. Current FreeTube code map

| Concern | Module |
|---|---|
| YouTube extractor (yt-dlp invocation, JSON parse, codec enums) | `src/youtube/` |
| Selected-stream descriptors + Producer translation boundary | `src/youtube/stream_format.ml`, `src/youtube/producer_bridge.ml` |
| `Producer` abstraction (phantom kinds, kind witness GADT, GADT-indexed `Meta.t`, errors, segment, codec carriers) | `src/producer/` |
| HTTP byte-range transport (own error type) | `src/http_range/` |
| YouTube VOD sources (fMP4, WebM) over byte-range | `src/stream_producer/source/` |
| Container parsers (BMFF / EBML) | `src/container/` |
