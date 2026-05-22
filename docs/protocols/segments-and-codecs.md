# Segments and Codecs — Byte-Level Protocol Reference

This document describes the container records and codec bitstreams that the
FreeTube streaming pipeline parses, splits, and reassembles. It is a protocol
reference, not a tutorial.

Conventions:

- Integers are big-endian unless marked `LE`.
- Bit fields are listed most-significant bit first.
- BMFF box types are 4-byte ASCII codes.
- EBML element IDs include their VINT marker bits.
- Empirical FreeTube behavior is explicitly labelled.

---

## 1. Containers

### 1.1 ISO Base Media File Format (MP4 / fMP4)

Reference: ISO/IEC 14496-12, ISO/IEC 14496-14, ISO/IEC 23009-1, ISO/IEC
14496-15, AV1 Codec ISO Media File Format Binding.

#### 1.1.1 Box Header

Base header:

```
size:u32 BE | type:[4]ASCII
```

| `size` | Meaning |
|--------|---------|
| `0` | Box extends to end of file or containing box. |
| `1` | 8-byte `largesize:u64 BE` follows `type`. |
| `2..7` | Invalid normal box size. |
| `>=8` | Total box size, including header. |

If `type == "uuid"`, a 16-byte extended type follows `type` or `largesize`.

| Form | Header bytes |
|------|--------------|
| normal | 8 |
| large size | 16 |
| uuid | 24 |
| large size + uuid | 32 |

`FullBox` body prefix:

```
version:u8 | flags:u24 BE
```

#### 1.1.2 Typical Fragmented MP4 Box Tree

Typical YouTube fMP4 order:

```
file
├── ftyp
├── moov
│   ├── mvhd
│   ├── trak *
│   │   ├── tkhd
│   │   └── mdia
│   │       ├── mdhd
│   │       ├── hdlr
│   │       └── minf
│   │           └── stbl
│   │               └── stsd
│   │                   └── avc1/avc3/hev1/hvc1/av01/vp09/mp4a/Opus
│   │                       └── avcC/hvcC/av1C/vpcC/esds/dOps
│   └── mvex
│       └── trex *
├── sidx                 optional
├── emsg                 optional
├── prft                 optional
├── moof
│   ├── mfhd
│   └── traf *
│       ├── tfhd
│       ├── tfdt
│       └── trun *
├── mdat
├── moof
├── mdat
└── mfra                 optional
    ├── tfra *
    └── mfro
```

Empirically observed (FreeTube): fused live MP4 blobs may be
`ftyp | moov | emsg? | prft? | sidx? | moof | mdat`. FreeTube's fused-fragment
splitter keeps only `ftyp` + `moov` for the init segment and drops `emsg`,
`prft`, and `sidx` from init bytes.

#### 1.1.3 File Type Box (`ftyp`)

Reference: ISO/IEC 14496-12.

Body:

```
major_brand:[4]
minor_version:u32
compatible_brands:[4] *
```

Common brands:

| Brand | Meaning |
|-------|---------|
| `isom` | ISO base media file. |
| `iso5` | ISO BMFF version 5. |
| `iso6` | ISO BMFF version 6. |
| `iso8` | ISO BMFF version 8. |
| `mp41` | MP4 v1. |
| `mp42` | MP4 v2. |
| `dash` | DASH-compatible. |
| `dby1` | Dolby profile indicator. |
| `av01` | AV1 compatibility. |
| `cmfc` | CMAF chunk/fragment compatibility. |

Empirically observed (FreeTube): Samsung TV playback requires
`major_brand == "isom"` for some fragmented MP4 streams.

#### 1.1.4 Movie and Track Metadata (`moov`, `trak`)

Reference: ISO/IEC 14496-12.

`moov` children relevant to segmentation:

| Box | Fields |
|-----|--------|
| `mvhd` | Movie `timescale`, movie `duration`. |
| `trak` | Track metadata. |
| `mvex` | Fragment defaults container. |
| `trex` | `track_ID`, `default_sample_description_index`, `default_sample_duration`, `default_sample_size`, `default_sample_flags`. |

`mvhd` after `FullBox`:

| Version | Time fields |
|---------|-------------|
| `0` | `creation_time:u32`, `modification_time:u32`, `timescale:u32`, `duration:u32` |
| `1` | `creation_time:u64`, `modification_time:u64`, `timescale:u32`, `duration:u64` |

`trak` structure:

```
trak
├── tkhd
└── mdia
    ├── mdhd
    ├── hdlr
    └── minf
        └── stbl
            └── stsd
```

Important fields:

| Path | Field |
|------|-------|
| `tkhd` | `track_ID:u32` |
| `tkhd` | `width:u32`, `height:u32` as 16.16 fixed point |
| `mdhd` | per-track `timescale:u32`, `duration:u32/u64`, `language:u16` |
| `hdlr` | `handler_type:[4]`, commonly `vide`, `soun`, `subt` |
| `stsd` | sample descriptions, one entry per codec configuration |

`mdhd` after `FullBox`:

| Version | Layout |
|---------|--------|
| `0` | `creation_time:u32`, `modification_time:u32`, `timescale:u32`, `duration:u32`, `language+pre_defined:u32` |
| `1` | `creation_time:u64`, `modification_time:u64`, `timescale:u32`, `duration:u64`, `language+pre_defined:u32` |

`stsd` after `FullBox`:

```
entry_count:u32
sample_entry[entry_count]
```

Sample entries:

| Entry | Codec | Config box |
|-------|-------|------------|
| `avc1` / `avc3` | H.264/AVC | `avcC` |
| `hev1` / `hvc1` | HEVC/H.265 | `hvcC` |
| `av01` | AV1 | `av1C` |
| `vp09` | VP9 | `vpcC` |
| `mp4a` | AAC | `esds` |
| `Opus` | Opus | `dOps` |

#### 1.1.5 Segment Index Box (`sidx`)

Reference: ISO/IEC 14496-12.

`sidx` is a `FullBox`.

```
size:u32 | type:"sidx" | version:u8 | flags:u24
reference_ID:u32
timescale:u32
if version == 0:
  earliest_presentation_time:u32
  first_offset:u32
if version == 1:
  earliest_presentation_time:u64
  first_offset:u64
reserved:u16 = 0
reference_count:u16
reference[reference_count]
```

Each reference is 12 bytes:

```
reference_type:1 | referenced_size:31
subsegment_duration:u32
starts_with_SAP:1 | SAP_type:3 | SAP_delta_time:28
```

Reference word:

| Bits | Field |
|------|-------|
| `31` | `reference_type`; `0` media, `1` nested index |
| `30..0` | `referenced_size` in bytes |

SAP word:

| Bits | Field |
|------|-------|
| `31` | `starts_with_SAP` |
| `30..28` | `SAP_type` |
| `27..0` | `SAP_delta_time` |

Empirically observed (FreeTube): MP4 layout parsing scans header bytes for the
first top-level `sidx` before the first `moof`; segment byte offsets are
anchored at the first top-level `moof` byte in the fetched object.

#### 1.1.6 Movie Fragment (`moof`, `mfhd`, `traf`)

Reference: ISO/IEC 14496-12.

`mfhd` after `FullBox`:

```
sequence_number:u32
```

`traf` contains per-track fragment state. The track is identified by
`tfhd.track_ID`.

#### 1.1.7 Track Fragment Header (`tfhd`)

Reference: ISO/IEC 14496-12.

`tfhd` is a `FullBox`.

```
track_ID:u32
[optional fields selected by flags]
```

Optional fields, in order:

| Flag mask | Field |
|-----------|-------|
| `0x000001` | `base_data_offset:u64` |
| `0x000002` | `sample_description_index:u32` |
| `0x000008` | `default_sample_duration:u32` |
| `0x000010` | `default_sample_size:u32` |
| `0x000020` | `default_sample_flags:u32` |

Semantic flags:

| Flag mask | Meaning |
|-----------|---------|
| `0x010000` | duration-is-empty |
| `0x020000` | default-base-is-moof |

#### 1.1.8 Track Fragment Decode Time (`tfdt`)

Reference: ISO/IEC 14496-12.

`tfdt` is a `FullBox`.

| Version | Body |
|---------|------|
| `0` | `baseMediaDecodeTime:u32` |
| `1` | `baseMediaDecodeTime:u64` |

`baseMediaDecodeTime` is the cumulative decode time of the first sample in the
fragment, in the track timescale.

Empirically observed (FreeTube): transcoded fragments may need every
`moof/traf/tfdt` shifted by the source segment's timeline delta so playback
does not restart at zero at each segment boundary.

#### 1.1.9 Track Run (`trun`)

Reference: ISO/IEC 14496-12.

`trun` is a `FullBox`.

```
sample_count:u32
[data_offset:i32]            if flags & 0x000001
[first_sample_flags:u32]     if flags & 0x000004
sample records...
```

Per-sample optional fields, repeated `sample_count` times in order:

| Flag mask | Field |
|-----------|-------|
| `0x000100` | `sample_duration:u32` |
| `0x000200` | `sample_size:u32` |
| `0x000400` | `sample_flags:u32` |
| `0x000800` | `sample_composition_time_offset:u32` for v0, `i32` for v1 |

`sample_flags:u32` (ISO/IEC 14496-12 §8.8.3):

| Bits | Field |
|------|-------|
| `31..28` | reserved |
| `27..26` | `is_leading` |
| `25..24` | `sample_depends_on` |
| `23..22` | `sample_is_depended_on` |
| `21..20` | `sample_has_redundancy` |
| `19..17` | `sample_padding_value` |
| `16` | `sample_is_non_sync_sample` |
| `15..0` | `sample_degradation_priority` |

#### 1.1.10 Media Data (`mdat`)

Reference: ISO/IEC 14496-12.

`mdat` is opaque payload. Samples are concatenated. Sample byte boundaries come
from `trun.sample_size`, `tfhd.default_sample_size`, or `trex.default_sample_size`.
Sample meaning comes from the active `stsd` sample entry.

MP4 video samples for `avc1`, `hev1`, and `av01` carry length-prefixed or
OBU-framed codec units as specified by the sample entry, not MPEG-TS Annex B
start-code framing.

#### 1.1.11 Event Message (`emsg`)

Reference: ISO/IEC 23009-1.

Version 0 body:

```
scheme_id_uri:string\0
value:string\0
timescale:u32
presentation_time_delta:u32
event_duration:u32
id:u32
message_data:u8[]
```

Version 1 body:

```
timescale:u32
presentation_time:u64
event_duration:u32
id:u32
scheme_id_uri:string\0
value:string\0
message_data:u8[]
```

Empirically observed (FreeTube): YouTube live uses `scheme_id_uri` prefixes
`http://youtube.com/streaming/metadata/segment/`; `message_data` is a
`Key: Value\r\n` blob.

#### 1.1.12 Producer Reference Time (`prft`)

Reference: ISO/IEC 14496-12.

`prft` is a `FullBox`.

```
reference_track_ID:u32
ntp_timestamp:u64
media_time:u32   if version == 0
media_time:u64   if version == 1
```

`ntp_timestamp` is a wall-clock anchor. `media_time` is in the referenced
track's media timescale.

#### 1.1.13 Movie Fragment Random Access (`mfra`, `tfra`, `mfro`)

Reference: ISO/IEC 14496-12.

`mfra` is an end-of-file random access container:

```
mfra
├── tfra *
└── mfro
```

`tfra` stores track fragment random-access entries. `mfro` stores `mfra` size.
FreeTube does not consume this table.

#### 1.1.14 Codec Configuration Boxes in `stsd`

Reference: ISO/IEC 14496-15, ISO/IEC 14496-3, AV1 Codec ISO Media File Format
Binding, VP Codec ISO Media File Format Binding, Opus in ISO Base Media File
Format.

| Sample entry | Child box | Payload |
|--------------|-----------|---------|
| `avc1` / `avc3` | `avcC` | AVCDecoderConfigurationRecord |
| `hev1` / `hvc1` | `hvcC` | HEVCDecoderConfigurationRecord |
| `av01` | `av1C` | AV1CodecConfigurationRecord |
| `vp09` | `vpcC` | VPCodecConfigurationBox |
| `mp4a` | `esds` | ES_Descriptor with AudioSpecificConfig in DecoderSpecificInfo |
| `Opus` | `dOps` | OpusSpecificBox |

---

### 1.2 EBML / Matroska / WebM

Reference: EBML specification, Matroska specification, WebM container
guidelines.

#### 1.2.1 VINT Encoding

The first byte's leftmost set bit determines total length, 1 to 8 bytes.

| First byte | Length | Value bits in first byte |
|------------|--------|--------------------------|
| `1xxx_xxxx` | 1 | 7 |
| `01xx_xxxx` | 2 | 6 |
| `001x_xxxx` | 3 | 5 |
| `0001_xxxx` | 4 | 4 |
| `0000_1xxx` | 5 | 3 |
| `0000_01xx` | 6 | 2 |
| `0000_001x` | 7 | 1 |
| `0000_0001` | 8 | 0 |

Rules:

| Context | Marker bit |
|---------|------------|
| Element ID | Included in the ID; do not strip. |
| Data size | Excluded from the value; strip it. |

Unknown data length: all size-VINT value bits set to `1`.

Examples:

| Bytes | Meaning as size VINT |
|-------|----------------------|
| `FF` | 1-byte unknown size |
| `7F FF` | 2-byte unknown size |
| `01 FF FF FF FF FF FF FF` | 8-byte unknown size |

#### 1.2.2 Top-Level Structure

Reference: Matroska / WebM EBML specifications.

```
EBML Header (0x1A45DFA3)
Segment     (0x18538067)
├── SeekHead (0x114D9B74)
├── Info     (0x1549A966)
├── Tracks   (0x1654AE6B)
├── Cues     (0x1C53BB6B)
├── Cluster  (0x1F43B675) *
└── Tags     (0x1254C367) optional
```

Grammar:

```
ebml-file    = ebml-header segment
segment      = id(0x18538067) size-vint segment-body
segment-body = *(seek-head / info / tracks / cues / cluster / tags / other)
```

Empirically observed (FreeTube): WebM init bytes are constructed as
`EBML header | Segment ID | unknown-size VINT | Info | Tracks`.

#### 1.2.3 `Info`

Reference: Matroska specification.

`Info` ID: `0x1549A966`.

| Element | ID | Type | Meaning |
|---------|----|------|---------|
| `TimestampScale` | `0x2AD7B1` | unsigned integer | Nanoseconds per tick; default `1_000_000`. |
| `Duration` | `0x4489` | float32/float64 | Duration in timestamp ticks. |
| `MuxingApp` | `0x4D80` | UTF-8 | Muxer name. |
| `WritingApp` | `0x5741` | UTF-8 | Writer name. |

```
seconds = timestamp * TimestampScale / 1_000_000_000
```

#### 1.2.4 `Tracks`

Reference: Matroska / WebM specifications.

```
Tracks (0x1654AE6B)
└── TrackEntry (0xAE) *
    ├── TrackNumber (0xD7)
    ├── TrackUID
    ├── TrackType (0x83)
    ├── CodecID (0x86)
    ├── CodecPrivate (0x63A2)
    ├── Video (0xE0)
    └── Audio (0xE1)
```

`TrackType`:

| Value | Meaning |
|-------|---------|
| `1` | video |
| `2` | audio |
| `17` | subtitle |

Codec IDs:

| `CodecID` | Payload |
|-----------|---------|
| `V_AV1` | AV1 low-overhead OBUs. |
| `V_VP9` | VP9 frames. |
| `V_VP9.2` | VP9 profile 2 frames. |
| `V_AVC` | H.264 frames per Matroska mapping. |
| `A_OPUS` | Opus packets. |

`CodecPrivate (0x63A2)`:

| Codec | Blob |
|-------|------|
| VP9 | VP codec configuration payload equivalent to `vpcC` fields. |
| Opus | Full `OpusHead` packet including `OpusHead` magic. |
| H.264 | AVC private configuration per Matroska mapping. |

`Video (0xE0)`:

| Element | ID | Type |
|---------|----|------|
| `PixelWidth` | `0xB0` | unsigned integer |
| `PixelHeight` | `0xBA` | unsigned integer |
| `FrameRate` | `0x2383E3` | float |

`Audio (0xE1)`:

| Element | ID | Type |
|---------|----|------|
| `SamplingFrequency` | `0xB5` | float |
| `Channels` | `0x9F` | unsigned integer |

#### 1.2.5 `Cues`

Reference: Matroska specification.

```
Cues (0x1C53BB6B)
└── CuePoint (0xBB) *
    ├── CueTime (0xB3):u64
    └── CueTrackPositions (0xB7) *
        └── CueClusterPosition (0xF1):u64
```

| Field | Meaning |
|-------|---------|
| `CueTime` | Timestamp in `TimestampScale` ticks. |
| `CueClusterPosition` | Byte offset into `Segment`, from start of `Segment` data section. |

Empirically observed (FreeTube): absolute cluster offset is
`segment_data_start + CueClusterPosition`. Cluster byte length is the next cue's
offset minus current offset; the final cluster extends to content length.

#### 1.2.6 `Cluster` and `SimpleBlock`

Reference: Matroska / WebM specifications.

```
Cluster (0x1F43B675)
├── Timestamp   (0xE7):u64
├── SimpleBlock (0xA3) *
└── BlockGroup  (0xA0) *
```

`SimpleBlock` payload is raw binary, not EBML:

```
track_number:VINT | timecode:i16 BE | flags:u8 | laced_frames
```

Flags:

| Bit | Field | Meaning |
|-----|-------|---------|
| `7` | keyframe | Keyframe if `1`. |
| `6` | reserved | zero |
| `5` | reserved | zero |
| `4` | reserved | zero |
| `3` | invisible | Not displayed if `1`. |
| `2..1` | lacing | `00` none, `01` Xiph, `10` fixed, `11` EBML. |
| `0` | discardable | May be discarded. |

No lacing: remaining bytes are one complete codec frame/packet.

Xiph lacing:

```
frame_count_minus_1:u8
size[frame_count - 1] as (0xFF * then final <0xFF)
frame[frame_count]
```

Fixed lacing:

```
frame_count_minus_1:u8
frame[frame_count] equal-sized
```

EBML lacing:

```
frame_count_minus_1:u8
first_frame_size:VINT
signed_size_delta[frame_count - 2]:EBML signed VINT
frame[frame_count]
```

#### 1.2.7 `Tags`

Reference: Matroska specification.

```
Tags (0x1254C367)
└── Tag (0x7373) *
    └── SimpleTag (0x67C8) *
        ├── TagName   (0x45A3)
        └── TagString (0x4487)
```

Empirically observed (FreeTube): YouTube live metadata may be stored under
`SimpleTag` entries whose `TagName` begins with
`http://youtube.com/streaming/metadata/segment/`.

#### 1.2.8 Unknown-Size `Segment` Trick

Reference: EBML specification.

```
Segment ID (0x18538067) | size-VINT(all value bits 1) | Info | Tracks | ...
```

An unknown-size `Segment` tells streaming demuxers to read until EOF.

Empirically observed (FreeTube): FreeTube rewrites the `Segment` data-size VINT
to all value bits set when constructing WebM init segments for VOD and fused
live splitting.

---

### 1.3 MPEG-TS

Reference: ISO/IEC 13818-1, ITU-T H.222.0, RFC 8216.

#### 1.3.1 188-Byte Packet

```
sync_byte:8 = 0x47
transport_error_indicator:1
payload_unit_start_indicator:1
transport_priority:1
PID:13
transport_scrambling_control:2
adaptation_field_control:2
continuity_counter:4
adaptation_field and/or payload
```

Header bytes:

| Byte | Bits | Field |
|------|------|-------|
| `0` | `7..0` | `0x47` |
| `1` | `7` | transport error indicator |
| `1` | `6` | payload unit start indicator |
| `1` | `5` | transport priority |
| `1..2` | `4..0,7..0` | PID |
| `3` | `7..6` | scrambling control |
| `3` | `5..4` | adaptation field control |
| `3` | `3..0` | continuity counter |

`adaptation_field_control`: `01` payload only, `10` adaptation only, `11`
adaptation then payload.

#### 1.3.2 Adaptation Field

Reference: ISO/IEC 13818-1.

```
adaptation_field_length:u8
if length > 0:
  discontinuity_indicator:1
  random_access_indicator:1
  elementary_stream_priority_indicator:1
  PCR_flag:1
  OPCR_flag:1
  splicing_point_flag:1
  transport_private_data_flag:1
  adaptation_field_extension_flag:1
  optional fields
  stuffing_byte:0xFF *
```

PCR, when `PCR_flag == 1`:

```
program_clock_reference_base:33
reserved:6
program_clock_reference_extension:9
```

`PCR = PCR_base * 300 + PCR_extension` in 27 MHz ticks.

#### 1.3.3 PAT

Reference: ISO/IEC 13818-1.

PAT PID is `0x0000`. It maps `program_number` to PMT PID.

```
table_id:u8 = 0x00
section_syntax_indicator:1 = 1
zero:1
reserved:2
section_length:12
transport_stream_id:u16
reserved:2
version_number:5
current_next_indicator:1
section_number:u8
last_section_number:u8
program loop
CRC_32:u32
```

Program loop entry:

```
program_number:u16
reserved:3
program_map_PID:13
```

#### 1.3.4 PMT

Reference: ISO/IEC 13818-1.

```
table_id:u8 = 0x02
section_syntax_indicator:1 = 1
zero:1
reserved:2
section_length:12
program_number:u16
reserved:2
version_number:5
current_next_indicator:1
section_number:u8
last_section_number:u8
reserved:3
PCR_PID:13
reserved:4
program_info_length:12
program_descriptors
stream loop
CRC_32:u32
```

Stream entry:

```
stream_type:u8
reserved:3
elementary_PID:13
reserved:4
ES_info_length:12
ES_descriptors
```

Relevant stream types:

| Type | Stream |
|------|--------|
| `0x1B` | H.264/AVC |
| `0x24` | HEVC/H.265 |
| `0x0F` | AAC ADTS |
| `0x11` | AAC LATM |

#### 1.3.5 PES Packet

Reference: ISO/IEC 13818-1.

```
start_code_prefix:24 = 0x000001
stream_id:u8
PES_packet_length:u16
```

Optional PES header prefix for audio/video streams:

```
'10':2 | PES_scrambling_control:2 | PES_priority:1 |
data_alignment_indicator:1 | copyright:1 | original_or_copy:1
PTS_DTS_flags:2 | ESCR_flag:1 | ES_rate_flag:1 | DSM_trick_mode_flag:1 |
additional_copy_info_flag:1 | PES_CRC_flag:1 | PES_extension_flag:1
PES_header_data_length:u8
```

PTS only, 5 bytes:

```
0010:4 | PTS[32..30]:3 | marker:1
PTS[29..15]:15 | marker:1
PTS[14..0]:15 | marker:1
```

PTS + DTS, 10 bytes:

```
0011:4 | PTS[32..30]:3 | marker:1
PTS[29..15]:15 | marker:1
PTS[14..0]:15 | marker:1
0001:4 | DTS[32..30]:3 | marker:1
DTS[29..15]:15 | marker:1
DTS[14..0]:15 | marker:1
```

PTS/DTS are 33-bit values in 90 kHz units.

#### 1.3.6 YouTube Use

Reference: ISO/IEC 13818-1, RFC 8216.

Empirically observed (FreeTube): YouTube HLS muxed variants emit MPEG-TS only,
with `avc1` + AAC. Each `.ts` segment is self-contained and carries its own
PAT, PMT, and IDR start.

---

## 2. Codec Bitstreams

Per-sample payload locations:

| Container | Payload |
|-----------|---------|
| MP4/fMP4 | `mdat` sample bytes delimited by `trun`/defaults. |
| WebM | `SimpleBlock` or `BlockGroup` frame bytes. |
| MPEG-TS | PES payload. |

### 2.1 H.264 / AVC

Reference: ITU-T H.264, ISO/IEC 14496-10, ISO/IEC 14496-15.

#### 2.1.1 NAL Unit Byte

```
forbidden_zero_bit:1 (=0) | nal_ref_idc:2 | nal_unit_type:5
```

Important NAL types:

| Type | Meaning |
|------|---------|
| `1` | non-IDR slice |
| `5` | IDR slice, keyframe |
| `6` | SEI |
| `7` | SPS |
| `8` | PPS |
| `9` | AUD |
| `12` | filler |
| `19` | auxiliary coded picture slice |
| `20` | scalable/multiview extension slice |

#### 2.1.2 Annex B Packaging

Reference: ITU-T H.264 Annex B.

Used in MPEG-TS:

```
start_code = 00 00 01 / 00 00 00 01
annexb_access_unit = *(start_code nal_unit)
```

Emulation prevention inserts `03` after `00 00` before a byte `00..03`:

| RBSP bytes | Byte stream bytes |
|------------|-------------------|
| `00 00 00` | `00 00 03 00` |
| `00 00 01` | `00 00 03 01` |
| `00 00 02` | `00 00 03 02` |
| `00 00 03` | `00 00 03 03` |

#### 2.1.3 AVCC Length-Prefixed Packaging

Reference: ISO/IEC 14496-15.

Used in MP4:

```
avcc_sample = *(nal_size nal_unit)
nal_size = unsigned BE integer, lengthSizeMinusOne + 1 bytes
```

`lengthSizeMinusOne` is in `avcC`; common value `3` means 4-byte NAL lengths.

Identifying a keyframe in MP4: parse length-prefixed NAL units and look for
`nal_unit_type == 5`.

#### 2.1.4 `avcC`

Reference: ISO/IEC 14496-15.

```
configurationVersion:u8 = 1
AVCProfileIndication:u8
profile_compatibility:u8
AVCLevelIndication:u8
reserved:6 = 0x3F | lengthSizeMinusOne:2
reserved:3 = 0x07 | numOfSequenceParameterSets:5
(sequenceParameterSetLength:u16, sequenceParameterSetNALUnit) *
numOfPictureParameterSets:u8
(pictureParameterSetLength:u16, pictureParameterSetNALUnit) *
```

For profiles including `100`, `110`, `122`, `144`, `244`:

```
reserved:6 = 0x3F | chroma_format:2
reserved:5 = 0x1F | bit_depth_luma_minus8:3
reserved:5 = 0x1F | bit_depth_chroma_minus8:3
numOfSequenceParameterSetExt:u8
(sequenceParameterSetExtLength:u16, sequenceParameterSetExtNALUnit) *
```

---

### 2.2 HEVC / H.265

Reference: ITU-T H.265, ISO/IEC 23008-2, ISO/IEC 14496-15.

#### 2.2.1 NAL Unit Header

Two bytes:

```
forbidden_zero_bit:1 | nal_unit_type:6 | nuh_layer_id:6 | nuh_temporal_id_plus1:3
```

Important NAL types:

| Type | Meaning |
|------|---------|
| `16..23` | IRAP range |
| `19` | IDR_W_RADL |
| `20` | IDR_N_LP |
| `21` | CRA_NUT |
| `32` | VPS_NUT |
| `33` | SPS_NUT |
| `34` | PPS_NUT |
| `35` | AUD_NUT |
| `39` | prefix SEI |
| `40` | suffix SEI |

#### 2.2.2 Packaging

Reference: ITU-T H.265 Annex B, ISO/IEC 14496-15.

| Container | Packaging |
|-----------|-----------|
| MPEG-TS | Annex B start codes `00 00 01` or `00 00 00 01`. |
| MP4 `hev1`/`hvc1` | Length-prefixed NAL units; prefix length from `hvcC.lengthSizeMinusOne + 1`. |

HEVC RBSP uses the same `00 00 03` emulation-prevention rule as AVC.

#### 2.2.3 `hvcC`

Reference: ISO/IEC 14496-15.

```
configurationVersion:u8 = 1
general_profile_space:2 | general_tier_flag:1 | general_profile_idc:5
general_profile_compatibility_flags:u32
general_constraint_indicator_flags:48
general_level_idc:u8
reserved:4 = 0xF | min_spatial_segmentation_idc:12
reserved:6 = 0x3F | parallelismType:2
reserved:6 = 0x3F | chromaFormat:2
reserved:5 = 0x1F | bitDepthLumaMinus8:3
reserved:5 = 0x1F | bitDepthChromaMinus8:3
avgFrameRate:u16
constantFrameRate:2 | numTemporalLayers:3 | temporalIdNested:1 | lengthSizeMinusOne:2
numOfArrays:u8
array[ numOfArrays ]
```

Array layout:

```
array_completeness:1 | reserved:1 | NAL_unit_type:6
numNalus:u16
(nal_unit_length:u16, nal_unit_bytes) *
```

Typical arrays: VPS (`32`), SPS (`33`), PPS (`34`).

---

### 2.3 AV1

Reference: AV1 Bitstream & Decoding Process Specification, AV1 Codec ISO Media
File Format Binding.

#### 2.3.1 OBU Header

Byte 1:

```
obu_forbidden_bit:1 (=0) | obu_type:4 | obu_extension_flag:1 | obu_has_size_field:1 | obu_reserved_1bit:1 (=0)
```

If `obu_extension_flag == 1`, byte 2:

```
temporal_id:3 | spatial_id:2 | reserved:3
```

If `obu_has_size_field == 1`, unsigned LEB128 `obu_size` follows.

OBU types:

| Type | Meaning |
|------|---------|
| `1` | sequence header |
| `2` | temporal delimiter |
| `3` | frame header |
| `4` | tile group |
| `5` | metadata |
| `6` | frame, header plus tile group |
| `7` | redundant frame header |
| `8` | tile list |
| `15` | padding |

#### 2.3.2 Low-Overhead Bitstream

Reference: AV1 Bitstream & Decoding Process Specification.

Used in MP4 `mdat` samples and WebM blocks:

```
low_overhead_bitstream = *(obu_header obu_size? obu_payload)
```

AV1 in containers uses OBUs concatenated with size fields.

#### 2.3.3 Annex B AV1

Reference: AV1 Bitstream & Decoding Process Specification.

Raw AV1 Annex B uses length-delimited temporal units and frame units:

```
temporal_unit_size leb128 | temporal_unit
frame_unit_size leb128    | frame_unit
obu_size leb128           | obu_without_size_field
```

It is not the MP4/WebM sample format.

#### 2.3.4 `av1C`

Reference: AV1 Codec ISO Media File Format Binding.

```
marker:1 (=1) | version:7 (=1)
seq_profile:3 | seq_level_idx_0:5
seq_tier_0:1 | high_bitdepth:1 | twelve_bit:1 | monochrome:1 |
  chroma_subsampling_x:1 | chroma_subsampling_y:1 | chroma_sample_position:2
reserved:3 (=0) | initial_presentation_delay_present:1 |
  initial_presentation_delay_minus_one:4
configOBUs:u8[]
```

`configOBUs` is concatenated OBUs, typically sequence header plus metadata.

---

### 2.4 VP9 / VP9.2

Reference: VP9 Bitstream & Decoding Process Specification, VP Codec ISO Media
File Format Binding, WebM codec mappings.

#### 2.4.1 Uncompressed Header Prefix

VP9 frame headers are bit-aligned and begin at frame byte 0. VP9 reads bits
from MSB to LSB within each byte (standard bit order, per VP9 Bitstream &
Decoding Process Specification v0.7 §8.1); fields below are in syntax order.
Note: the profile field encodes its low bit before its high bit in syntax
order (`profile_low_bit` before `profile_high_bit`), so
`profile = (profile_high_bit << 1) | profile_low_bit`.

```
frame_marker:2 (=0b10)
profile_low_bit:1
profile_high_bit:1
if profile == 3: reserved_zero:1
show_existing_frame:1
```

If `show_existing_frame == 1`:

```
frame_to_show_map_idx:3
```

Otherwise:

```
frame_type:1          0 KEYFRAME, 1 INTER
show_frame:1
error_resilient_mode:1
```

For keyframes:

```
frame_sync_code:24 = 0x498342
color_config
frame_size
render_size
```

Frame sync bytes: `49 83 42`.

#### 2.4.2 `vpcC`

Reference: VP Codec ISO Media File Format Binding.

`vpcC` is a `FullBox`.

```
profile:u8
level:u8
bitDepth:4 | chromaSubsampling:3 | videoFullRangeFlag:1
colourPrimaries:u8
transferCharacteristics:u8
matrixCoefficients:u8
codecInitializationDataSize:u16
codecInitializationData:u8[codecInitializationDataSize]
```

For VP9, `codecInitializationDataSize` is normally `0`; required decoder
configuration is in-band.

Empirically observed (FreeTube): VP9 and VP9.2 YouTube streams are delivered
through the WebM/Cues segmented path with `CodecID` `V_VP9` or `V_VP9.2`.

---

### 2.5 AAC

Reference: ISO/IEC 14496-3, ISO/IEC 13818-7, ISO/IEC 13818-1.

#### 2.5.1 ADTS Header

ADTS is used for AAC in MPEG-TS. Header length is 7 bytes, or 9 bytes when
`protection_absent == 0`.

| Byte | Bits | Field |
|------|------|-------|
| `0` | `7..0` | `syncword[11..4] = 0xFF` |
| `1` | `7..4` | `syncword[3..0] = 0xF` |
| `1` | `3` | MPEG version, `0` MPEG-4, `1` MPEG-2 |
| `1` | `2..1` | layer = `0` |
| `1` | `0` | protection_absent |
| `2` | `7..6` | profile_minus_1 |
| `2` | `5..2` | sampling_frequency_index |
| `2` | `1` | private_bit |
| `2` | `0` | channel_configuration[2] |
| `3` | `7..6` | channel_configuration[1..0] |
| `3` | `5` | original_copy |
| `3` | `4` | home |
| `3` | `3` | copyright_id_bit |
| `3` | `2` | copyright_id_start |
| `3` | `1..0` | aac_frame_length[12..11] |
| `4` | `7..0` | aac_frame_length[10..3] |
| `5` | `7..5` | aac_frame_length[2..0] |
| `5` | `4..0` | buffer_fullness[10..6] |
| `6` | `7..2` | buffer_fullness[5..0] |
| `6` | `1..0` | number_of_raw_data_blocks_in_frame |
| `7..8` | all | CRC if present |

`aac_frame_length` includes header and payload.

Sampling frequency indices:

| Index | Hz |
|-------|----|
| `0` | 96000 |
| `1` | 88200 |
| `2` | 64000 |
| `3` | 48000 |
| `4` | 44100 |
| `5` | 32000 |
| `6` | 24000 |
| `7` | 22050 |
| `8` | 16000 |
| `9` | 12000 |
| `10` | 11025 |
| `11` | 8000 |
| `12` | 7350 |

#### 2.5.2 AudioSpecificConfig

Reference: ISO/IEC 14496-3.

Stored inside `esds.ES_Descriptor.DecoderSpecificInfo` for MP4 `mp4a`.

```
audioObjectType:5
if audioObjectType == 31:
  audioObjectTypeExt:6
  audioObjectType = 32 + audioObjectTypeExt
samplingFrequencyIndex:4
if samplingFrequencyIndex == 15:
  samplingFrequency:u24
channelConfiguration:4
AOT-specific bits
```

For AAC-LC (`audioObjectType == 2`), `GASpecificConfig` starts:

```
frameLengthFlag:1
dependsOnCoreCoder:1
if dependsOnCoreCoder: coreCoderDelay:14
extensionFlag:1
```

#### 2.5.3 Raw AAC vs ADTS

Reference: ISO/IEC 14496-3, ISO/IEC 14496-14, ISO/IEC 13818-1.

| Container | AAC payload |
|-----------|-------------|
| MP4 `mp4a` | Raw AAC frame, no sync word. |
| MPEG-TS | ADTS frame. |

MP4-to-TS form prepends ADTS from AudioSpecificConfig values. TS-to-MP4 form
strips ADTS and stores AudioSpecificConfig in `esds`.

---

### 2.6 Opus

Reference: RFC 6716, RFC 7845, RFC 3533, Matroska Opus mapping, Opus in ISO
Base Media File Format.

#### 2.6.1 Packet TOC Byte

Reference: RFC 6716.

```
config:5 | s:1 | c:2
```

| Bits | Field | Meaning |
|------|-------|---------|
| `7..3` | `config` | Mode, bandwidth, frame-size selector. |
| `2` | `s` | Stereo flag. |
| `1..0` | `c` | Frame count code. |

Frame count code:

| `c` | Meaning |
|-----|---------|
| `0` | 1 frame |
| `1` | 2 equal-size frames |
| `2` | 2 different-size frames |
| `3` | Arbitrary count; next byte is `vbr:1 | padding:1 | count:6`. |

#### 2.6.2 `OpusHead`

Reference: RFC 7845, Matroska Opus mapping.

Ogg Opus identification packet:

```
magic:[8] = "OpusHead"
version:u8 = 1
channel_count:u8
pre_skip:u16 LE
input_sample_rate:u32 LE
output_gain:i16 LE
channel_mapping_family:u8
if channel_mapping_family != 0:
  stream_count:u8
  coupled_count:u8
  channel_mapping:u8[channel_count]
```

| Container | Storage |
|-----------|---------|
| Ogg | First Opus identification packet, including `OpusHead` magic. |
| WebM `A_OPUS` | `CodecPrivate` contains the full `OpusHead` packet, including magic. |
| MP4 `Opus` | `dOps` stores equivalent fields without `OpusHead` magic. |

#### 2.6.3 `OpusTags`

Reference: RFC 7845.

Ogg-only comment packet:

```
magic:[8] = "OpusTags"
vendor_string_length:u32 LE
vendor_string:u8[vendor_string_length]
user_comment_list_length:u32 LE
(length:u32 LE, utf8_comment:u8[length]) *
```

Not present in MP4 `dOps` or WebM `CodecPrivate`.

#### 2.6.4 Ogg Encapsulation

Reference: RFC 3533, RFC 7845.

```
"OggS"
version:u8 = 0
header_type:u8
granule_position:i64 LE
bitstream_serial:u32 LE
page_sequence_number:u32 LE
crc:u32 LE
seg_count:u8
segment_table:u8[seg_count]
page_data:u8[sum(segment_table)]
```

Segments `0..254` terminate a packet after that many bytes. Segment `255`
continues the packet into the next segment.

#### 2.6.5 `dOps`

Reference: Opus in ISO Base Media File Format.

`dOps` body inside MP4 `Opus` sample entry:

```
Version:u8 = 0
OutputChannelCount:u8
PreSkip:u16 BE
InputSampleRate:u32 BE
OutputGain:i16 BE
ChannelMappingFamily:u8
if ChannelMappingFamily != 0:
  StreamCount:u8
  CoupledCount:u8
  ChannelMapping:u8[OutputChannelCount]
```

Empirically observed (FreeTube): `dOps` uses big-endian multi-byte fields,
unlike `OpusHead`, which uses little-endian. This is a common cross-container
pitfall.

---

## 3. FreeTube Segmentation Notes

These are observed FreeTube pipeline facts, not normative container rules.

### 3.1 MP4 / SIDX

Empirically observed (FreeTube):

- Header bytes are scanned as top-level BMFF boxes.
- `sidx` supplies segment sizes and durations.
- First media byte is the first top-level `moof`.
- Fused live init extraction keeps only `ftyp` + `moov`.
- Media segments are byte ranges containing `moof` + `mdat` fragment data.

### 3.2 WebM / Cues

Empirically observed (FreeTube):

- `Cues` supplies cluster offsets and timestamps.
- `CueClusterPosition` is relative to the start of `Segment` data, not file byte zero.
- Init is `EBML header | Segment ID | unknown-size VINT | Info | Tracks`.
- Media segments begin at `Cluster` element IDs.

### 3.3 HLS-TS

Empirically observed (FreeTube):

- YouTube HLS muxed variants are complete `.ts` URLs.
- YouTube HLS-TS normally does not use `#EXT-X-MAP` or byte ranges.
- Each TS object contains PAT, PMT, and random-access media for the segment.
