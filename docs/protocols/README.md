# FreeTube Protocol Reference

This directory contains a self-contained, **implementation-agnostic** description of
every external protocol a FreeTube-equivalent server has to speak. Each sub-document
is written so that a port to another language can be performed without reading the
existing Rust source.

The documents intentionally do not contain code snippets, ffmpeg invocations, or
references to Rust-specific data structures. Where empirical behaviour deviates from
or extends the published specifications, the document labels the claim
"Empirically observed (FreeTube)" so a re-implementer knows it is field-tested rather
than spec-mandated.

## Sub-documents

| Document | Scope |
|----------|-------|
| [airplay2.md](airplay2.md) | AirPlay 2 device discovery (mDNS), HAP pair-setup (SRP-6a) and pair-verify (Curve25519 + Ed25519), the ChaCha20-Poly1305 encrypted transport, RTSP/HTTP control surface, MRP framing, NTP time sync, and the playback command flow. |
| [dlna.md](dlna.md) | DLNA / UPnP MediaRenderer: SSDP discovery (multicast + unicast), device description parsing, AVTransport:1 / RenderingControl:1 / ConnectionManager:1 SOAP actions, DIDL-Lite metadata, and device-profile quirks for LG WebOS, Samsung Tizen, and Yamaha. |
| [youtube-ingest.md](youtube-ingest.md) | Invoking `yt-dlp` (CLI flags, JS runtime, cookie format), the `--dump-single-json` schema returned per video, format/stream selection rules, signature-cipher decoding overview, live-stream `http_dash_segments` protocol, and the YouTube-specific HTTP headers (`X-Sequence-Num`, `X-Head-Seqnum`, `X-Head-Time-Millis`, `X-Segment-Lmt`) and in-band metadata (WebM `Tags`, MP4 `emsg`). |
| [hls-dash.md](hls-dash.md) | HLS m3u8 grammar (RFC 8216), DASH MPD schema (ISO/IEC 23009-1), required tags and attributes per profile, version negotiation, codec-string conventions (RFC 6381), DRM signalling, and the cross-format transformations needed to repackage a single source as both HLS and DASH. |
| [segments-and-codecs.md](segments-and-codecs.md) | Byte-level container layout for ISO BMFF / fMP4 (boxes, SIDX, init segment, fragments) and Matroska / WebM (EBML, Segment, Cues, Tags); how to split video and audio at byte boundaries; how to read timestamps and metadata from packets; codec bitstream details for AVC, HEVC, AV1, VP9, AAC, and Opus. |

## How to navigate

* Start with **youtube-ingest.md** to understand what the upstream gives you.
* Read **segments-and-codecs.md** before either manifest doc — every byte you serve
  has to be addressable within a container described there.
* **hls-dash.md** consumes the layout produced by segments-and-codecs.md and turns
  it into a playlist.
* **dlna.md** and **airplay2.md** are sink-specific control protocols; they describe
  how to *advertise* a manifest URL to a renderer, not how to build it.

## External specifications

For full reference, the canonical external specifications are:

| Topic | Standard |
|-------|----------|
| mDNS / DNS-SD | RFC 6762, RFC 6763 |
| SRP-6a (HAP pair-setup) | RFC 5054 |
| HKDF | RFC 5869 |
| ChaCha20-Poly1305 AEAD | RFC 8439 |
| Ed25519 | RFC 8032 |
| X25519 / Curve25519 | RFC 7748 |
| HLS | RFC 8216 |
| DASH | ISO/IEC 23009-1 |
| ISO BMFF / fMP4 | ISO/IEC 14496-12 |
| MPEG-2 TS | ISO/IEC 13818-1 |
| Matroska / EBML | IETF RFC 9559 / Matroska v4 |
| WebM | https://www.webmproject.org/docs/container/ |
| RFC 6381 codec strings | RFC 6381 |
| AAC | ISO/IEC 14496-3 |
| AV1 | AV1 Bitstream & Decoding Process Specification |
| HEVC | ITU-T H.265 / ISO/IEC 23008-2 |
| AVC | ITU-T H.264 / ISO/IEC 14496-10 |
| VP9 | https://www.webmproject.org/vp9/ |
| Opus | RFC 6716, RFC 7845 (in-Ogg/WebM) |
| UPnP Device Architecture | UPnP UDA 2.0 |
| UPnP AVTransport:1 | UPnP-av-AVTransport-v1-Service |
| UPnP ConnectionManager:1 | UPnP-av-ConnectionManager-v1-Service |
| UPnP RenderingControl:1 | UPnP-av-RenderingControl-v1-Service |
| DLNA Guidelines | DLNA Networked Device Interoperability Guidelines |

## Document conventions

* Tables in preference to prose where the structure permits it.
* Byte offsets in container layouts use 0-based, inclusive notation: `bytes[0..4]` =
  the first four bytes.
* All multi-byte integers in ISO BMFF and EBML are big-endian unless explicitly noted
  otherwise.
* "Spec" = the published standard listed above for the section in question.
  "Empirically observed (FreeTube)" = a constraint discovered during integration that
  is not stated by any standard but is required for at least one shipping device.
