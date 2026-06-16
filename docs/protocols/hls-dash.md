# HLS and DASH Manifest Formats — Protocol Reference

This document describes the player-facing HLS and DASH manifest shapes used by FreeTube, and the abstract transformations between them. It is a reference for manifest syntax, segment addressing, codec signaling, and FreeTube-specific interoperability rules.

---

## 1. HLS (RFC 8216)

HTTP Live Streaming uses UTF-8 `.m3u8` playlists. A master playlist selects renditions. A media playlist enumerates media segments.

### 1.1 Playlist Header Tags

| Tag | Playlist | Form | Semantics |
|-----|----------|------|-----------|
| `#EXTM3U` | Master, media | Literal first non-empty line | Identifies an Extended M3U playlist. Required. |
| `#EXT-X-VERSION` | Master, media | `#EXT-X-VERSION:<n>` | HLS protocol compatibility version. Required when the playlist uses features newer than version 1. |
| `#EXT-X-INDEPENDENT-SEGMENTS` | Master, media | Literal tag | Every media segment begins with an independent decoding point. Applies to all segments in the playlist scope. |

### 1.2 HLS Version Feature Reference

| Version | Feature class | Tags / attributes that require at least this version |
|---------|---------------|------------------------------------------------------|
| 1 | Baseline | Integer `#EXTINF` durations, MPEG-TS segments. |
| 2 | Encryption IV | `IV` attribute on `#EXT-X-KEY`. |
| 3 | Floating durations | Decimal `#EXTINF:<duration>`. |
| 4 | Byte range and I-frame playlists | `#EXT-X-BYTERANGE`, `#EXT-X-I-FRAMES-ONLY`. (`#EXT-X-MEDIA`, `#EXT-X-I-FRAME-STREAM-INF`, and the `AUDIO`, `VIDEO`, `SUBTITLES`, `CLOSED-CAPTIONS` attributes of `#EXT-X-STREAM-INF` are backward-compatible to version 1 per RFC 8216 §7; `#EXT-X-DISCONTINUITY-SEQUENCE` has no stated version requirement in RFC 8216 §7.) |
| 5 | Key formats, map for I-frame playlists | `KEYFORMAT`, `KEYFORMATVERSIONS`, `#EXT-X-MAP` in I-frame playlists. |
| 6 | Initialization map in ordinary media playlists | `#EXT-X-MAP` in a media playlist without `#EXT-X-I-FRAMES-ONLY`. |
| 7 | CEA-708 digital captions | `SERVICE` values for the `INSTREAM-ID` attribute of `#EXT-X-MEDIA` (CEA-708 digital captioning service blocks). fMP4 carriage via `#EXT-X-MAP` in a non-I-frame playlist requires version 6, not 7 (RFC 8216 §7). |

Empirically observed (FreeTube): FreeTube emits `#EXT-X-VERSION:7` for generated HLS playlists. fMP4 carriage with `#EXT-X-MAP` in an ordinary media playlist requires version 6 per RFC 8216 §4.3.2.5 and §7; FreeTube conservatively declares version 7 because it is universally accepted by Apple TV, iPhone, Chromium, LG WebOS, and DLNA renderers. Version 7 is specified by RFC 8216 §7 for `SERVICE` values in `INSTREAM-ID` of `#EXT-X-MEDIA`, which FreeTube does not currently emit.

---

## 2. HLS Master Playlist

A master playlist contains variant streams and optional alternate renditions.

### 2.1 Master Playlist Shape

```m3u8
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-SESSION-DATA:DATA-ID="com.apple.hls.title",VALUE="Example title"

#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Audio",LANGUAGE="und",DEFAULT=YES,AUTOSELECT=YES,URI="audio/media.m3u8",CHANNELS="2"

#EXT-X-STREAM-INF:BANDWIDTH=4000000,AVERAGE-BANDWIDTH=3500000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2",FRAME-RATE=30.000,AUDIO="audio",SUBTITLES="subs",CLOSED-CAPTIONS=NONE,HDCP-LEVEL=NONE,VIDEO-RANGE=SDR
media.m3u8
```

### 2.2 `#EXT-X-MEDIA`

Form:

```m3u8
#EXT-X-MEDIA:<attribute-list>
```

| Attribute | Values | Required | Semantics |
|-----------|--------|----------|-----------|
| `TYPE` | `AUDIO`, `SUBTITLES`, `CLOSED-CAPTIONS`, `VIDEO` | Yes | Rendition type. FreeTube player-facing use is normally `AUDIO`. |
| `GROUP-ID` | Quoted string | Yes | Rendition group identifier. Referenced by `AUDIO`, `SUBTITLES`, or `CLOSED-CAPTIONS` on `#EXT-X-STREAM-INF`. |
| `NAME` | Quoted string | Yes | Human-readable rendition name. Unique within the group. FreeTube uses the source audio stream's `format_note` (e.g. `"medium"`), falling back to `language` then `format_id` when absent. |
| `LANGUAGE` | Quoted RFC 5646 language tag | No | Primary language, e.g. `"en"`, `"und"`. |
| `DEFAULT` | `YES`, `NO` | No | `YES` marks the rendition selected by default. Default is `NO`. |
| `AUTOSELECT` | `YES`, `NO` | No | `YES` allows automatic client selection by language/device settings. |
| `URI` | Quoted URI | Required except some `CLOSED-CAPTIONS` uses | Media playlist URI for the rendition. Not used for in-band closed captions. |
| `CHANNELS` | Quoted channel count / layout | Required when two renditions have same codec but different channel count | Audio channel signaling, e.g. `"2"`, `"6"`, `"2/JOC"`. |

FreeTube current shape:

```m3u8
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Audio",DEFAULT=YES,AUTOSELECT=YES,URI="/session/<id>/audio/media.m3u8"
```

### 2.3 `#EXT-X-STREAM-INF`

Form:

```m3u8
#EXT-X-STREAM-INF:<attribute-list>
<media-playlist-uri>
```

| Attribute | Values | Required | Semantics |
|-----------|--------|----------|-----------|
| `BANDWIDTH` | Decimal integer bits/s | Yes | Peak segment bitrate for the variant. |
| `AVERAGE-BANDWIDTH` | Decimal integer bits/s | No | Average variant bitrate. |
| `RESOLUTION` | `<width>x<height>` | Required when video present | Encoded pixel dimensions. |
| `CODECS` | Quoted comma-separated RFC 6381 strings | Recommended; effectively required for compatibility | All sample codecs needed by the variant, e.g. `"hvc1.2.4.L120.B0,mp4a.40.2"`. |
| `FRAME-RATE` | Decimal frames/s | Recommended when video present | Maximum video frame rate. HLS allows up to three decimal places. |
| `AUDIO` | Quoted `GROUP-ID` | Required when using an audio rendition group | Links the variant to `#EXT-X-MEDIA:TYPE=AUDIO`. |
| `SUBTITLES` | Quoted `GROUP-ID` | No | Links subtitle rendition group. |
| `CLOSED-CAPTIONS` | Quoted `GROUP-ID` or `NONE` | No | Links closed-caption group, or declares no closed captions. |
| `HDCP-LEVEL` | `TYPE-0`, `NONE` | No | HDCP requirement for output protection. |
| `VIDEO-RANGE` | `SDR`, `PQ`, `HLG` | No | Dynamic range signaling. `PQ` covers HDR10-style transfer; Dolby Vision may also require codec/profile signaling. |

Empirically observed (FreeTube): Apple TV rejects or stalls on otherwise valid HLS variants when `FRAME-RATE` is omitted. FreeTube emits `FRAME-RATE` on every `#EXT-X-STREAM-INF`, defaulting to `30.000` when the source does not report an FPS.

Empirically observed (FreeTube): Apple TV supports H.264 and HEVC through HLS, including HEVC HDR10 and Dolby Vision within the device codec ceiling, provided `FRAME-RATE` is present. AV1 is not supported on Apple TV.

### 2.4 `#EXT-X-SESSION-DATA`

Form:

```m3u8
#EXT-X-SESSION-DATA:DATA-ID="<reverse-dns-id>",VALUE="<string>",LANGUAGE="<tag>"
#EXT-X-SESSION-DATA:DATA-ID="<reverse-dns-id>",URI="<metadata-uri>",LANGUAGE="<tag>"
```

| Attribute | Values | Required | Semantics |
|-----------|--------|----------|-----------|
| `DATA-ID` | Quoted reverse-DNS string | Yes | Metadata key. |
| `VALUE` | Quoted string | Required unless `URI` present | Inline metadata value. Mutually exclusive with `URI`. |
| `URI` | Quoted URI | Required unless `VALUE` present | External JSON metadata resource. Mutually exclusive with `VALUE`. |
| `LANGUAGE` | Quoted RFC 5646 language tag | No | Language of the value. |

FreeTube current shape:

```m3u8
#EXT-X-SESSION-DATA:DATA-ID="com.apple.hls.title",VALUE="<video title>"
```

### 2.5 `#EXT-X-I-FRAME-STREAM-INF`

Form:

```m3u8
#EXT-X-I-FRAME-STREAM-INF:<attribute-list>
```

| Attribute | Values | Required | Semantics |
|-----------|--------|----------|-----------|
| `BANDWIDTH` | Decimal integer bits/s | Yes | Peak I-frame-only stream bitrate. |
| `AVERAGE-BANDWIDTH` | Decimal integer bits/s | No | Average bitrate. |
| `CODECS` | Quoted RFC 6381 string list | Recommended | Codecs needed by the I-frame stream. |
| `RESOLUTION` | `<width>x<height>` | No | Encoded pixel dimensions. |
| `VIDEO-RANGE` | `SDR`, `PQ`, `HLG` | No | Dynamic range signaling. |
| `URI` | Quoted URI | Yes | I-frame-only media playlist URI. |
| `HDCP-LEVEL` | `TYPE-0`, `NONE` | No | Output protection requirement. |

FreeTube emits I-frame-only playlists for VOD streams when storyboard thumbnail data is available. The I-frame stream is generated by transcoding YouTube storyboard JPEG thumbnails into H.264 all-keyframe fMP4 segments, producing a lightweight trick-play stream for Apple TV / AirPlay seeking previews. The I-frame playlist uses `#EXT-X-I-FRAMES-ONLY` and references per-frame fMP4 segments under the `iframe/` path prefix. This tag is gated by the device profile (`iframe_stream = true` for Apple and Generic vendors).

---

## 3. HLS Media Playlist

A media playlist enumerates segments for one rendition.

### 3.1 Media Playlist Shape: fMP4 VOD

```m3u8
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-MAP:URI="init.mp4",BYTERANGE="1200@0"
#EXTINF:5.973,
#EXT-X-BYTERANGE:341220@1200
media.mp4
#EXTINF:6.006,
#EXT-X-BYTERANGE:298112@342420
media.mp4
#EXT-X-ENDLIST
```

### 3.2 Media Playlist Tags

| Tag | Form | Semantics |
|-----|------|-----------|
| `#EXT-X-TARGETDURATION` | `#EXT-X-TARGETDURATION:<seconds>` | Integer ceiling of the maximum `#EXTINF` duration in the playlist. |
| `#EXT-X-MEDIA-SEQUENCE` | `#EXT-X-MEDIA-SEQUENCE:<number>` | Sequence number of the first segment URI in the playlist. Defaults to `0` if absent. |
| `#EXT-X-DISCONTINUITY-SEQUENCE` | `#EXT-X-DISCONTINUITY-SEQUENCE:<number>` | Sequence number of the first discontinuity marker. Used to align renditions across playlist reloads. |
| `#EXT-X-PLAYLIST-TYPE` | `#EXT-X-PLAYLIST-TYPE:VOD` or `#EXT-X-PLAYLIST-TYPE:EVENT` | Mutability contract. `VOD` is immutable. `EVENT` can append only. Live sliding playlists omit this tag. |
| `#EXT-X-MAP` | `#EXT-X-MAP:URI="<uri>",BYTERANGE="<len>@<off>"` | Media initialization section. Required for fMP4 segments. `BYTERANGE` is optional; if absent, the entire `URI` resource is the init section. |
| `#EXTINF` | `#EXTINF:<duration>,<title>` | Duration of the following media segment in seconds. Title is optional and may be empty. |
| `#EXT-X-BYTERANGE` | `#EXT-X-BYTERANGE:<len>[@<off>]` | Byte range of the following media segment in its URI resource. If `@<off>` is absent, offset is previous range end. |
| `#EXT-X-PROGRAM-DATE-TIME` | `#EXT-X-PROGRAM-DATE-TIME:<iso8601>` | Wall-clock timestamp for the first sample of the next segment (ISO/IEC 8601:2004 format, e.g. `2024-01-01T00:01:00.000Z`; RFC 8216 §4.3.2.6). Applies by timeline extrapolation to following segments. |
| `#EXT-X-DISCONTINUITY` | Literal tag before a segment | Marks a discontinuity in timestamps, track layout, encoding parameters, or file format. |
| `#EXT-X-START` | `#EXT-X-START:TIME-OFFSET=<seconds>,PRECISE=YES|NO` | Preferred initial playback position relative to playlist start (`>=0`) or end (`<0`). |
| `#EXT-X-ENDLIST` | Literal tag | Playlist is complete. Omission means the client must treat the playlist as reloadable. |

### 3.3 Playlist Type Semantics

| Type | Tags | Mutability | Sequence behavior | Client expectation |
|------|------|------------|-------------------|--------------------|
| VOD | `#EXT-X-PLAYLIST-TYPE:VOD`, `#EXT-X-ENDLIST` | Static | `#EXT-X-MEDIA-SEQUENCE` typically `0` | Client can cache and seek over the full duration. |
| EVENT | `#EXT-X-PLAYLIST-TYPE:EVENT`, no `#EXT-X-ENDLIST` until complete | Append-only | Initial sequence stays stable; new segments append | Client reloads and can seek over the accumulated event window. |
| Live sliding window | No `#EXT-X-PLAYLIST-TYPE`, no `#EXT-X-ENDLIST` | Mutable window | `#EXT-X-MEDIA-SEQUENCE` increments as old segments roll off | Client reloads, plays near live edge, and cannot assume old URIs remain listed. |

FreeTube current live shape:

```m3u8
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:110
#EXT-X-MAP:URI="/session/<id>/init"
#EXT-X-START:TIME-OFFSET=-30,PRECISE=YES
#EXT-X-PROGRAM-DATE-TIME:2024-01-01T00:01:00Z
#EXTINF:6.000,
/session/<id>/seg/110
#EXTINF:6.000,
/session/<id>/seg/111
```

### 3.4 Segment Carriage

| Carriage | Segment bytes | Initialization | HLS tags | Notes |
|----------|---------------|----------------|----------|-------|
| MPEG-TS | Sequence of 188-byte transport stream packets | Self-contained per segment | `#EXTINF` + segment URI; no `#EXT-X-MAP` | Legacy HLS carriage. Segment URI normally identifies one `.ts` resource. |
| fMP4 / CMAF | `[moof][mdat]` per media segment | `[ftyp][moov]` init segment | `#EXT-X-MAP` required, then `#EXTINF` and optional `#EXT-X-BYTERANGE` | Requires version 7 for compatibility. Movie-fragment-relative addressing is required. |
| WebM | WebM cluster-aligned fragments | EBML header + Segment Info + Tracks | Not standardized by RFC 8216 | Empirically observed (FreeTube): Chromium-based players and LG WebOS accept WebM segments through HLS-like playlists; Apple TV does not. |

Empirically observed (FreeTube): Muxed YouTube HLS-TS sources are self-contained and FreeTube omits `#EXT-X-MAP` for those sessions. Segmented MP4/WebM sessions use `/init` plus `/seg/<n>` routes.

---

## 4. DASH MPD (ISO/IEC 23009-1)

Dynamic Adaptive Streaming over HTTP uses an XML Media Presentation Description (MPD). The MPD contains one or more periods, each period contains adaptation sets, each adaptation set contains representations.

### 4.1 MPD Root

Static VOD shape:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011"
     profiles="urn:mpeg:dash:profile:isoff-on-demand:2011"
     type="static"
     mediaPresentationDuration="PT120.0S"
     minBufferTime="PT2S">
  <Period>
  </Period>
</MPD>
```

Dynamic live shape:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011"
     profiles="urn:mpeg:dash:profile:isoff-live:2011"
     type="dynamic"
     availabilityStartTime="2024-01-01T00:00:00Z"
     minimumUpdatePeriod="PT6S"
     timeShiftBufferDepth="PT4H"
     suggestedPresentationDelay="PT36S"
     minBufferTime="PT6S">
  <Period>
  </Period>
</MPD>
```

| Attribute | Values | Required | Semantics |
|-----------|--------|----------|-----------|
| `xmlns` | `urn:mpeg:dash:schema:mpd:2011` | Yes | DASH MPD namespace. |
| `profiles` | `urn:mpeg:dash:profile:isoff-on-demand:2011`, `urn:mpeg:dash:profile:isoff-live:2011`, others | Yes | DASH profile constraints. FreeTube uses ISO BMFF on-demand for static and ISO BMFF live for dynamic MPDs. |
| `type` | `static`, `dynamic` | No; default is `static` | Static VOD vs live/reloadable presentation. |
| `mediaPresentationDuration` | ISO 8601 duration | Required for bounded static presentations | Total presentation duration. VOD-only in FreeTube. |
| `availabilityStartTime` | RFC 3339 date-time | Required for dynamic timing model | Wall-clock time corresponding to MPD timeline zero. Live-only. |
| `minimumUpdatePeriod` | ISO 8601 duration | Dynamic | Minimum interval before clients reload the MPD. |
| `timeShiftBufferDepth` | ISO 8601 duration | Dynamic DVR | Duration of live content available for time-shift playback. |
| `suggestedPresentationDelay` | ISO 8601 duration | Dynamic | Recommended delay behind live edge. |
| `minBufferTime` | ISO 8601 duration | Yes in FreeTube | Minimum buffering recommendation. |

Empirically observed (FreeTube): For live `dynamic`, FreeTube derives `availabilityStartTime = first_frame_us - first_sq * segment_dur_us` when in-band metadata is available. Without that anchor it uses `now - 30 * segment_dur`. FreeTube sets `suggestedPresentationDelay = 6 * segment_dur`.

### 4.2 Period / AdaptationSet / Representation

Shape:

```xml
<Period start="PT0S" duration="PT120S">
  <AdaptationSet contentType="video"
                 mimeType="video/mp4"
                 codecs="avc1.640028"
                 width="1920"
                 height="1080"
                 frameRate="30"
                 bitstreamSwitching="true">
    <Role schemeIdUri="urn:mpeg:dash:role:2011" value="main"/>
    <Representation id="video-1080p" bandwidth="4000000">
    </Representation>
  </AdaptationSet>

  <AdaptationSet contentType="audio"
                 mimeType="audio/mp4"
                 codecs="mp4a.40.2"
                 lang="und">
    <Role schemeIdUri="urn:mpeg:dash:role:2011" value="main"/>
    <Representation id="audio" bandwidth="128000">
    </Representation>
  </AdaptationSet>
</Period>
```

| Element / attribute | Values | Semantics |
|---------------------|--------|-----------|
| `Period@start` | ISO 8601 duration | Period start time relative to presentation. Optional for first period. |
| `Period@duration` | ISO 8601 duration | Period duration. Optional when implied by MPD duration or live timeline. |
| `AdaptationSet@contentType` | `video`, `audio`, `text` | Track type. |
| `AdaptationSet@mimeType` | `video/mp4`, `audio/mp4`, `video/webm`, `audio/webm` | Container MIME type. Can also be set on `Representation`. |
| `AdaptationSet@codecs` | RFC 6381 codec string | Codec common to all representations in the set. Can also be set on `Representation`. |
| `AdaptationSet@width`, `@height` | Decimal integer pixels | Video dimensions. Usually omitted for audio. |
| `AdaptationSet@frameRate` | Integer or rational, e.g. `30`, `30000/1001` | Video frame rate. |
| `AdaptationSet@bitstreamSwitching` | `true`, `false` | Indicates representations can be switched without decoder reinitialization. |
| `Representation@id` | XML string | Identifier used by templates and clients. |
| `Representation@bandwidth` | Decimal integer bits/s | Required representation bitrate. |
| `Role@schemeIdUri` | `urn:mpeg:dash:role:2011` | DASH role vocabulary. |
| `Role@value` | `main`, `alternate`, `subtitle`, etc. | `main` marks default/primary track. |

FreeTube current shape places one video representation in one video adaptation set, and optionally one audio representation in one audio adaptation set. Current FreeTube MPDs set `mimeType`, `codecs`, `width`, `height`, `frameRate`, and `bitstreamSwitching` on the video `AdaptationSet`; `Representation` carries `id` and `bandwidth`.

### 4.3 MIME Types Per Container

| Container | Video MIME | Audio MIME | Codec examples |
|-----------|------------|------------|----------------|
| fMP4 / ISO BMFF | `video/mp4` | `audio/mp4` | `avc1.640028`, `hvc1.2.4.L120.B0`, `av01.0.05M.08`, `mp4a.40.2` |
| WebM | `video/webm` | `audio/webm` | `vp09.00.50.08`, `opus` |

Empirically observed (FreeTube): Some DLNA renderers require MP4 initialization segments to advertise `isom` as the major brand. FreeTube has brand-patching support for those renderers; this is container interoperability behavior, not a DASH or HLS manifest rule.

---

## 5. DASH Segment Addressing

DASH uses exactly one segment addressing model per representation: `SegmentBase`, `SegmentList`, or `SegmentTemplate`.

### 5.1 `SegmentBase`: Single File with Internal Index

Shape:

```xml
<Representation id="video" bandwidth="4000000" codecs="avc1.640028">
  <BaseURL>https://example.com/video.mp4</BaseURL>
  <SegmentBase indexRange="1200-1879" indexRangeExact="true">
    <Initialization range="0-1199"/>
  </SegmentBase>
</Representation>
```

| Element / attribute | Values | Semantics |
|---------------------|--------|-----------|
| `BaseURL` | Absolute or relative URL | Resource containing initialization bytes, index bytes, and media subsegments. |
| `SegmentBase@indexRange` | `<start>-<end>` byte range | Byte range of the index box/structure. For ISO BMFF this is normally the `sidx` box. |
| `SegmentBase@indexRangeExact` | `true`, `false` | `true` means `indexRange` exactly covers the index. |
| `Initialization@range` | `<start>-<end>` byte range | Byte range of initialization data, normally `[ftyp][moov]`. |

Client behavior: fetch `Initialization@range`, fetch `indexRange`, parse the index, derive subsegment durations and byte ranges, then fetch media subsegments with HTTP Range requests.

For ISO BMFF, `indexRange` references `sidx`. For WebM DASH, `indexRange` can reference WebM Cues. Empirically observed (FreeTube): LG WebOS accepts WebM/Cues DASH in some modes; Apple TV does not accept WebM media for HLS playback.

### 5.2 `SegmentList`: Explicit Segment URL List

Shape:

```xml
<Representation id="video" bandwidth="4000000" codecs="avc1.640028">
  <SegmentList timescale="1000" duration="6000">
    <Initialization sourceURL="init.mp4"/>
    <SegmentURL media="seg-0.m4s" mediaRange="0-341219" indexRange="0-679"/>
    <SegmentURL media="seg-1.m4s" mediaRange="0-298111"/>
  </SegmentList>
</Representation>
```

| Element / attribute | Values | Semantics |
|---------------------|--------|-----------|
| `SegmentList@timescale` | Decimal integer ticks/s | Timescale for `duration`. |
| `SegmentList@duration` | Decimal integer ticks | Constant segment duration when no timeline is present. |
| `Initialization@sourceURL` | URI | Initialization segment URL. |
| `Initialization@range` | `<start>-<end>` byte range | Optional byte range within `sourceURL`. |
| `SegmentURL@media` | URI | Segment resource URL. |
| `SegmentURL@mediaRange` | `<start>-<end>` byte range | Optional byte range within `media`. |
| `SegmentURL@indexRange` | `<start>-<end>` byte range | Optional per-segment index range. |

### 5.3 `SegmentTemplate`: Templated URLs

Constant-duration shape:

```xml
<Representation id="video" bandwidth="4000000" codecs="avc1.640028">
  <SegmentTemplate media="$RepresentationID$/$Number$.m4s"
                   initialization="$RepresentationID$/init.m4s"
                   timescale="1000"
                   duration="6000"
                   startNumber="0"/>
</Representation>
```

Timeline shape:

```xml
<Representation id="video" bandwidth="4000000" codecs="avc1.640028">
  <SegmentTemplate media="/session/abc/seg/$Number$"
                   initialization="/session/abc/init"
                   timescale="1000"
                   startNumber="110">
    <SegmentTimeline>
      <S t="660000" d="6000" r="29"/>
    </SegmentTimeline>
  </SegmentTemplate>
</Representation>
```

| Element / attribute | Values | Semantics |
|---------------------|--------|-----------|
| `SegmentTemplate@media` | URI template | Segment URL template. |
| `SegmentTemplate@initialization` | URI template | Initialization segment URL template. |
| `SegmentTemplate@timescale` | Decimal integer ticks/s | Timescale for `duration`, `S@t`, and `S@d`. |
| `SegmentTemplate@duration` | Decimal integer ticks | Constant duration for every segment when no `SegmentTimeline` is present. |
| `SegmentTemplate@startNumber` | Decimal integer | Number assigned to the first segment in the addressing scheme. Defaults to `1` by DASH rules; FreeTube sets it explicitly. |
| `SegmentTimeline` | Child element | Explicit segment timing. Required for variable durations and commonly used for live windows. |
| `S@t` | Decimal integer ticks | Earliest presentation time of the first segment in this run. Optional when implied. |
| `S@d` | Decimal integer ticks | Segment duration. Required. |
| `S@r` | Decimal integer repeat count | Number of additional segments with the same duration. `r="29"` means 30 segments total. Negative values can mean repeat until next `S` or period end. |

Template variables:

| Variable | Expansion |
|----------|-----------|
| `$RepresentationID$` | `Representation@id`. |
| `$Number$` | Segment number, starting at `startNumber`. |
| `$Time$` | Segment presentation time from `SegmentTimeline` (`S@t` plus repeats). |
| `$Bandwidth$` | `Representation@bandwidth`. |
| `$$` | Literal dollar sign. |

FreeTube current shape uses `SegmentTemplate` with `timescale="1000"`, `initialization="<base>/init"`, `media="<base>/seg/$Number$"`, and a `SegmentTimeline`. For live windows, `startNumber` is the absolute source sequence number and `S@t = startNumber * segment_duration_ms`.

---

## 6. RFC 6381 Codec Strings

HLS `CODECS` and DASH `codecs` use RFC 6381 codec identifiers. HLS puts all codecs needed by a variant in one comma-separated list. DASH normally puts one codec per adaptation set or representation.

### 6.1 Video Codecs Used by FreeTube Targets

| Codec | Form | Fields | Example |
|-------|------|--------|---------|
| H.264 / AVC | `avc1.<profile-IDC><constraints><level-IDC>` | Three hex bytes: profile IDC, constraint flags, level IDC. | `avc1.640028` = High profile (`0x64`), constraints `0x00`, level `0x28` = 4.0. |
| HEVC / H.265 | `hvc1.<general_profile_space><general_profile_idc>.<compatibility>.<tier_flag><level_idc>.<constraint_flags>` | Profile space/profile, compatibility flags, tier (`L` main or `H` high) plus level, constraint bytes. | `hvc1.2.4.L120.B0`. |
| AV1 | `av01.<profile>.<level><tier>.<bit_depth>.<monochrome>.<chroma_subsampling>.<color_primaries>.<transfer_characteristics>.<matrix_coefficients>.<video_full_range>` | Profile, level+tier, bit depth, monochrome, chroma subsampling, color primaries, transfer, matrix, full-range flag. Later fields may be omitted when default. | `av01.0.05M.08`. |
| VP9 | `vp09.<profile>.<level>.<bit_depth>.<chroma_subsampling>.<color_primaries>.<transfer_characteristics>.<matrix_coefficients>.<video_full_range>` | Profile, level, bit depth, chroma, color primaries, transfer, matrix, full-range flag. | `vp09.00.50.08`. |

Notes:

| Codec | FreeTube target use | Interop notes |
|-------|---------------------|---------------|
| `avc1.*` | H.264 fallback and transcode target for broad playback. | Works in HLS and DASH with MP4/fMP4 carriage. |
| `hvc1.*` | HEVC/HDR-capable Apple TV and DLNA devices. | Prefer `hvc1` signaling: VPS/SPS/PPS are stored **out-of-band** in the `HEVCDecoderConfigurationRecord` (sample entry box). Use `hev1` if parameter sets may appear in-band in the NAL stream. Apple HLS stacks expect `hvc1`. |
| `av01.*` | AV1-capable browsers and selected DLNA devices. | Empirically observed (FreeTube): Apple TV codec ceiling excludes AV1. |
| `vp09.*` | WebM VP9 / VP9.2 for Chromium/LG paths. | HLS WebM is not RFC 8216 carriage. DASH WebM uses WebM MIME types. |

### 6.2 Audio Codecs Used by FreeTube Targets

| Codec | RFC 6381 string | Semantics | Container notes |
|-------|-----------------|-----------|-----------------|
| AAC-LC | `mp4a.40.2` | MPEG-4 Audio Object Type 2. | MP4/fMP4 audio. |
| HE-AAC v1 | `mp4a.40.5` | MPEG-4 Audio Object Type 5, SBR. | MP4/fMP4 audio. |
| HE-AAC v2 | `mp4a.40.29` | MPEG-4 Audio Object Type 29, PS + SBR. | MP4/fMP4 audio. |
| Opus | `opus` | Opus audio. | WebM in FreeTube's YouTube source path; not accepted by all HLS sinks. |

Empirically observed (FreeTube): AirPlay/HLS playback is constrained to AAC audio; Opus routes through WebM-oriented playback paths and is not accepted by Apple TV HLS playback.

---

## 7. DASH to HLS Transformations

These transformations are manifest and addressing transformations only. They assume compatible encoded samples and container fragments. They do not define re-encoding.

### 7.1 DASH `SegmentBase` fMP4 + SIDX to HLS VOD fMP4 Byterange

Input shape:

```xml
<Representation id="v" bandwidth="4000000" codecs="avc1.640028">
  <BaseURL>video.mp4</BaseURL>
  <SegmentBase indexRange="1200-1879" indexRangeExact="true">
    <Initialization range="0-1199"/>
  </SegmentBase>
</Representation>
```

Transformation:

| DASH input | HLS output |
|------------|------------|
| `BaseURL` | Segment URI after each `#EXT-X-BYTERANGE`, unless byte ranges are proxied through separate URLs. |
| `Initialization@range = a-b` | `#EXT-X-MAP:URI="<BaseURL>",BYTERANGE="<b-a+1>@<a>"`. |
| `SegmentBase@indexRange` | Parser input only. Read the `sidx` box; do not expose the index as an HLS segment. |
| `sidx` reference duration | `#EXTINF:<duration>,` in seconds. |
| `sidx` reference byte range | `#EXT-X-BYTERANGE:<len>@<offset>`. |
| Static presentation | `#EXT-X-PLAYLIST-TYPE:VOD` and `#EXT-X-ENDLIST`. |

Output shape:

```m3u8
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-MAP:URI="video.mp4",BYTERANGE="1200@0"
#EXTINF:5.973,
#EXT-X-BYTERANGE:341220@1880
video.mp4
#EXTINF:6.006,
#EXT-X-BYTERANGE:298112@343100
video.mp4
#EXT-X-ENDLIST
```

Rules:

| Rule | Reason |
|------|--------|
| Enumerate every `sidx` subsegment in media order. | HLS media playlists expose a flat ordered segment list. |
| Use one `#EXT-X-MAP` when all subsegments share the same initialization section. | fMP4 decoder state is stable across segments. |
| Do not insert `#EXT-X-DISCONTINUITY` between ordinary subsegments. | Same track layout, timestamps, and initialization section. |
| Use `#EXT-X-BYTERANGE` when multiple HLS segments address one resource. | Preserves single-file DASH storage without materializing segment URLs. |

### 7.2 DASH `SegmentTemplate` `$Number$` Live to HLS Live

Input shape:

```xml
<MPD type="dynamic"
     availabilityStartTime="2024-01-01T00:00:00Z"
     timeShiftBufferDepth="PT180S"
     suggestedPresentationDelay="PT36S">
  <Period>
    <AdaptationSet mimeType="video/mp4" codecs="avc1.640028" frameRate="30">
      <Representation id="video" bandwidth="4000000">
        <SegmentTemplate timescale="1000"
                         initialization="video/init.m4s"
                         media="video/$Number$.m4s"
                         duration="6000"
                         startNumber="1000"/>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
```

Transformation:

| DASH input | HLS output |
|------------|------------|
| `availabilityStartTime` | Wall-clock anchor for `#EXT-X-PROGRAM-DATE-TIME`. |
| `timeShiftBufferDepth` | Determines the oldest segment retained in the HLS sliding window. |
| Live edge | Highest segment number currently available. |
| Window start | `live_edge - timeShiftBufferDepth`, rounded to segment boundaries. |
| `SegmentTemplate@startNumber` | Absolute numbering basis. HLS `#EXT-X-MEDIA-SEQUENCE` is the first segment number in the current window. |
| `SegmentTemplate@initialization` | `#EXT-X-MAP:URI="<expanded initialization>"`. |
| `SegmentTemplate@media` | Segment URI after each `#EXTINF`, expanded with `$Number$`. |
| `duration / timescale` | `#EXTINF:<seconds>,` and `#EXT-X-TARGETDURATION`. |

Output shape:

```m3u8
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:1010
#EXT-X-MAP:URI="video/init.m4s"
#EXT-X-START:TIME-OFFSET=-30,PRECISE=YES
#EXT-X-PROGRAM-DATE-TIME:2024-01-01T00:01:00Z
#EXTINF:6.000,
video/1010.m4s
#EXTINF:6.000,
video/1011.m4s
```

Rules:

| Rule | Semantics |
|------|-----------|
| On each refresh, list only `[live_edge - timeShiftBufferDepth, live_edge]`. | Produces an HLS sliding window. |
| Set `#EXT-X-MEDIA-SEQUENCE` to the absolute first segment number of the window. | Preserves segment identity across reloads. |
| Emit one `#EXT-X-PROGRAM-DATE-TIME` before the first listed segment. | Anchors wall-clock playback; later segment times are derived from `#EXTINF`. |
| Omit `#EXT-X-ENDLIST` while the broadcast is active. | Signals reloadable live playlist. |
| Add `#EXT-X-ENDLIST` only after the broadcast is complete. | Converts live to complete VOD/event semantics. |

Empirically observed (FreeTube): FreeTube live HLS adds `#EXT-X-START:TIME-OFFSET=-30,PRECISE=YES` to land players roughly 30 seconds behind live edge.

---

## 8. HLS to DASH Transformations

### 8.1 HLS Master with Audio Group to DASH Separate Audio AdaptationSet

Input shape:

```m3u8
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="audio.m3u8",CHANNELS="2"
#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2",FRAME-RATE=30.000,AUDIO="audio"
video.m3u8
```

Transformation:

| HLS input | DASH output |
|-----------|-------------|
| `#EXT-X-STREAM-INF` + following URI | Video `Representation` in a video `AdaptationSet`. The URI supplies segment addressing for that representation. |
| `BANDWIDTH` | `Representation@bandwidth`. |
| `RESOLUTION=W×H` | `AdaptationSet@width=W`, `AdaptationSet@height=H` or representation-level equivalents. |
| `FRAME-RATE` | `AdaptationSet@frameRate`. |
| `CODECS="video,audio"` | Split by actual track. Video adaptation set gets the video codec only. Audio adaptation set gets the audio codec only. |
| `AUDIO="group"` | Select `#EXT-X-MEDIA TYPE=AUDIO GROUP-ID="group"` as a separate audio adaptation set. |
| Audio `URI` | Segment addressing source for audio representation. |
| `DEFAULT=YES,AUTOSELECT=YES` | `<Role schemeIdUri="urn:mpeg:dash:role:2011" value="main"/>`. |
| `LANGUAGE` | `AdaptationSet@lang`. |
| `CHANNELS` | DASH audio channel configuration descriptor when precise channel signaling is required. |

Output shape:

```xml
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011"
     profiles="urn:mpeg:dash:profile:isoff-on-demand:2011"
     type="static"
     mediaPresentationDuration="PT120S"
     minBufferTime="PT2S">
  <Period>
    <AdaptationSet contentType="video" mimeType="video/mp4" codecs="avc1.640028" width="1920" height="1080" frameRate="30">
      <Role schemeIdUri="urn:mpeg:dash:role:2011" value="main"/>
      <Representation id="video" bandwidth="4000000">
        <SegmentTemplate timescale="1000" initialization="video/init.m4s" media="video/seg/$Number$.m4s" startNumber="0">
          <SegmentTimeline>
            <S t="0" d="6000" r="19"/>
          </SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
    <AdaptationSet contentType="audio" mimeType="audio/mp4" codecs="mp4a.40.2" lang="en">
      <Role schemeIdUri="urn:mpeg:dash:role:2011" value="main"/>
      <Representation id="audio" bandwidth="128000">
        <SegmentTemplate timescale="1000" initialization="audio/init.m4s" media="audio/seg/$Number$.m4s" startNumber="0">
          <SegmentTimeline>
            <S t="0" d="6000" r="19"/>
          </SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
```

### 8.2 HLS fMP4 Byterange to DASH `SegmentList`

Input shape:

```m3u8
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-MAP:URI="media.mp4",BYTERANGE="1200@0"
#EXTINF:5.973,
#EXT-X-BYTERANGE:341220@1880
media.mp4
#EXTINF:6.006,
#EXT-X-BYTERANGE:298112@343100
media.mp4
#EXT-X-ENDLIST
```

Mapping:

| HLS input | DASH output |
|-----------|-------------|
| `#EXT-X-MAP URI` | `Initialization@sourceURL`. |
| `#EXT-X-MAP BYTERANGE="len@off"` | `Initialization@range="off-(off+len-1)"`. |
| Segment URI | `SegmentURL@media`. |
| `#EXT-X-BYTERANGE:len@off` | `SegmentURL@mediaRange="off-(off+len-1)"`. |
| `#EXTINF` durations | `SegmentTimeline` `S@d` values or `SegmentList@duration` when constant. |
| `#EXT-X-ENDLIST` | Static MPD when the full duration is known. |
| Missing `#EXT-X-ENDLIST` | Dynamic MPD or incomplete static MPD, depending on playlist type and reload behavior. |

---

## 9. WebM Track Packaging

| Context | Index structure | Manifest signaling | Interop |
|---------|-----------------|--------------------|---------|
| DASH WebM `SegmentBase` | WebM Cues, not ISO BMFF `sidx` | `mimeType="video/webm"` or `audio/webm`, `codecs="vp09..."` or `opus`, `SegmentBase@indexRange` referencing Cues | Empirically observed (FreeTube): accepted by some LG WebOS / browser paths. |
| DASH WebM `SegmentTemplate` | Server-side layout maps segment numbers to WebM cluster ranges | `SegmentTemplate initialization=".../init" media=".../seg/$Number$"` | FreeTube current player-facing DASH shape for VP9/WebM sessions. |
| HLS WebM | EBML init + WebM clusters addressed from an HLS-like playlist | `#EXT-X-MAP` plus `#EXTINF` segment URIs; not RFC 8216-defined carriage | Empirically observed (FreeTube): works on Chromium-based players and some LG WebOS devices; fails on Apple TV. |

FreeTube WebM initialization is an EBML header plus Segment Info plus Tracks, with the Segment size represented as unknown. Media segments are cluster-aligned byte ranges exposed through the same `/init` and `/seg/<n>` player-facing routes as MP4 sessions.

---

## 10. FreeTube-Specific Manifest Decisions

### 10.1 HLS

| Decision | Current FreeTube value | Status |
|----------|------------------------|--------|
| Protocol version | `#EXT-X-VERSION:7` | Empirically observed (FreeTube): broad compatibility for fMP4/CMAF-style output. |
| Independent segments | `#EXT-X-INDEPENDENT-SEGMENTS` in master playlist | Signals safe variant switching / segment starts. |
| Title metadata | `#EXT-X-SESSION-DATA:DATA-ID="com.apple.hls.title",VALUE="<title>"` | Metadata convenience for players. |
| Video variant FPS | Always emit `FRAME-RATE=<fps>`; default `30.000` if unknown | Empirically observed (FreeTube): required by Apple TV. |
| Audio group | `GROUP-ID="audio"`, `NAME="Audio"`, `DEFAULT=YES`, `AUTOSELECT=YES` | Used when a separate audio track exists. |
| VOD media sequence | `#EXT-X-MEDIA-SEQUENCE:0` | Static generated playlists start at zero. |
| VOD completion | `#EXT-X-ENDLIST` | Generated VOD playlists are complete. |
| fMP4/WebM init | `#EXT-X-MAP:URI="<base>/init"` | Omitted only when source segments are self-contained MPEG-TS. |
| Live sequence | `#EXT-X-MEDIA-SEQUENCE:<absolute source sequence>` | Preserves source sequence identity across reloads. |
| Live start | `#EXT-X-START:TIME-OFFSET=-30,PRECISE=YES` | Empirically observed (FreeTube): starts players behind live edge. |
| Live wall-clock | One `#EXT-X-PROGRAM-DATE-TIME` before first listed segment when an anchor exists | Derived from in-band first-frame wall-clock metadata. |

### 10.2 DASH

| Decision | Current FreeTube value | Status |
|----------|------------------------|--------|
| Static profile | `urn:mpeg:dash:profile:isoff-on-demand:2011` | Used with `type="static"`. |
| Live profile | `urn:mpeg:dash:profile:isoff-live:2011` | Used with `type="dynamic"`. |
| Static duration | `mediaPresentationDuration="PT...S"` | Derived from session duration when known. |
| Static buffer | `minBufferTime="PT2S"` | Fixed value for static MPDs. |
| Live update | `minimumUpdatePeriod="PT<segment_dur>S"` | Segment-duration reload cadence. |
| Live DVR | `timeShiftBufferDepth="PT4H"` | Four-hour live window advertised to players. |
| Live delay | `suggestedPresentationDelay="PT<6*segment_dur>S"` | Empirically observed (FreeTube): stable playback behind live edge. |
| Live AST | In-band anchor when available; otherwise `now - 30 * segment_dur` | Empirically observed (FreeTube): keeps player live-edge calculations inside the published timeline. |
| Segment addressing | `SegmentTemplate` with `SegmentTimeline` | FreeTube normalizes MP4 SIDX and WebM Cues into an internal segment layout, then exposes numbered routes. |
| Timescale | `timescale="1000"` | Segment durations and times are milliseconds. |
| Video routes | `initialization="<base>/init"`, `media="<base>/seg/$Number$"` | Player-facing route shape. |
| Audio routes | `initialization="<base>/audio/init"`, `media="<base>/audio/seg/$Number$"` | Separate audio adaptation set when audio exists. |
| WebM MIME | `video/webm` for VP9, `audio/webm` for Opus | Container signaling follows source container. |

---

## 11. Minimal FreeTube Wire Examples

### 11.1 HLS Master with Separate Audio

```m3u8
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-SESSION-DATA:DATA-ID="com.apple.hls.title",VALUE="Example"

#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Audio",DEFAULT=YES,AUTOSELECT=YES,URI="/session/abc/audio/media.m3u8"

#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080,FRAME-RATE=30.000,CODECS="avc1.640028,mp4a.40.2",AUDIO="audio"
/session/abc/media.m3u8
```

### 11.2 HLS VOD Media Playlist

```m3u8
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:5
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-MAP:URI="/session/abc/init"
#EXTINF:4.500,
/session/abc/seg/0
#EXTINF:4.500,
/session/abc/seg/1
#EXT-X-ENDLIST
```

### 11.3 DASH Static MPD with Video and Audio

```xml
<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011" type="static" mediaPresentationDuration="PT120.0S" minBufferTime="PT2S">
  <ProgramInformation><Title>Example</Title></ProgramInformation>
  <Period>
    <AdaptationSet mimeType="video/mp4" codecs="avc1.640028" width="1920" height="1080" frameRate="30" bitstreamSwitching="true">
      <Representation id="video" bandwidth="4000000">
        <SegmentTemplate timescale="1000" initialization="/session/abc/init" media="/session/abc/seg/$Number$" startNumber="0">
          <SegmentTimeline>
            <S t="0" d="5000" r="23"/>
          </SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
    <AdaptationSet mimeType="audio/mp4" codecs="mp4a.40.2" lang="und">
      <Representation id="audio" bandwidth="128000">
        <SegmentTemplate timescale="1000" initialization="/session/abc/audio/init" media="/session/abc/audio/seg/$Number$" startNumber="0">
          <SegmentTimeline>
            <S t="0" d="5000" r="23"/>
          </SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
```
