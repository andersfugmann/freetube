# MPEG-TS and Muxed Stream Handling

## Context

YouTube serves some streams (notably live HLS) as muxed MPEG-TS — video (H.264)
and audio (AAC) interleaved in a single transport stream. The current pipeline
assumes separate video and audio producers. This document describes how to
handle muxed MPEG-TS streams.

## Architecture: Demux Source

A muxed stream should be handled by a **demux source** that splits the single
muxed input into two independent `Producer.S` modules — one for video, one for
audio. These then feed into the standard per-kind pipeline
(`Container_to_fmp4 → Transcode → Cache → ...`).

```
                        ┌─── Video Producer.S ──→ video pipeline
  Muxed MPEG-TS ──→ Demux
                        └─── Audio Producer.S ──→ audio pipeline
```

The demux source:
- Fetches each TS segment once (shared fetch, cached)
- Parses PAT/PMT to identify video/audio PIDs
- Reassembles PES packets per PID
- Exposes two `Producer.S` modules with separate `init_segment` and
  `fetch_segment` — each returning fMP4 for its track

This means `Container_to_fmp4` for MPEG-TS is effectively embedded in the demux
source (it produces fMP4 directly), rather than being a separate functor in the
chain. The video/audio producers it exposes are already fMP4.

## MPEG-TS Packet Structure

Each segment is self-contained (PAT + PMT + PES in every segment):

```
Transport packet: 188 bytes
  sync_byte:        0x47
  PID:              13-bit (identifies stream)
  adaptation_field: optional (contains PCR, padding)
  payload:          variable (PES packet fragments)

Special PIDs:
  0x0000 = PAT (Program Association Table) → lists PMT PID
  PMT PID = Program Map Table → lists elementary stream PIDs + codec types
```

## PES Packet Reassembly

PES (Packetized Elementary Stream) packets span multiple TS packets:

```
PES header:
  start_code:       0x000001
  stream_id:        0xE0-0xEF (video), 0xC0-0xDF (audio)
  PES_packet_length: u16
  PTS_DTS_flags:    2 bits (10 = PTS only, 11 = PTS + DTS)

PTS/DTS: 33-bit values in 90 kHz clock (90000 ticks/second)
  Encoded as 5 bytes with marker bits:
    0010|PTS[32:30]|1 | PTS[29:15]|1 | PTS[14:0]|1
```

## H.264 (AVC) Frame Extraction

MPEG-TS carries H.264 in **Annex B** format:

```
Annex B:
  start_code (00 00 01 or 00 00 00 01) | NAL unit | ...

NAL unit types (first byte & 0x1F):
  1 = non-IDR slice (P/B frame)
  5 = IDR slice (keyframe)
  6 = SEI
  7 = SPS (Sequence Parameter Set)
  8 = PPS (Picture Parameter Set)
```

To produce fMP4:
1. Parse PES payload to extract NAL units (split on start codes)
2. Convert Annex B → length-prefix format (4-byte BE length + NAL data)
3. Extract SPS + PPS from first IDR → build `avcC` box for init segment
4. Each frame = concatenated length-prefixed NAL units → fMP4 sample
5. Keyframe detection: NAL type 5 present in access unit

### avcC Box (Decoder Configuration Record)

```
configurationVersion:    1
AVCProfileIndication:    SPS[1]
profile_compatibility:   SPS[2]
AVCLevelIndication:      SPS[3]
lengthSizeMinusOne:      3 (4-byte lengths)
numOfSequenceParameterSets: 1
  SPS length + SPS data
numOfPictureParameterSets: 1
  PPS length + PPS data
```

## AAC Audio Frame Extraction

MPEG-TS carries AAC in **ADTS** format:

```
ADTS header (7 bytes, no CRC; 9 bytes with CRC):
  syncword:                    0xFFF (12 bits)
  ID:                          1 bit (0=MPEG-4, 1=MPEG-2)
  protection_absent:           1 bit (1=no CRC)
  profile:                     2 bits (0=AAC-LC minus 1)
  sampling_frequency_index:    4 bits
  channel_configuration:       3 bits
  frame_length:                13 bits (includes header)
```

To produce fMP4:
1. Parse ADTS header to get frame boundaries and audio config
2. Strip ADTS header (7 or 9 bytes) → raw AAC frame = fMP4 sample
3. Build `esds` box (ES_Descriptor) with AudioSpecificConfig for init segment
4. Each sample duration = 1024 samples at the detected sample rate

### AudioSpecificConfig (for esds box)

```
audioObjectType:            5 bits (2 = AAC-LC)
samplingFrequencyIndex:     4 bits
channelConfiguration:       4 bits
```

### esds Box Structure

```
ES_Descriptor (tag 0x03):
  ES_ID: 0
  DecoderConfigDescriptor (tag 0x04):
    objectTypeIndication: 0x40 (Audio ISO/IEC 14496-3)
    streamType: 0x05 (audio)
    DecoderSpecificInfo (tag 0x05):
      AudioSpecificConfig bytes
```

## Timestamp Handling

- MPEG-TS uses 90 kHz clock for PTS/DTS
- fMP4 video typically uses timescale 90000 (can keep as-is) or 1000
- fMP4 audio uses sample rate as timescale (e.g. 44100, 48000)
- Conversion: `fmp4_time = pts_90k * target_timescale / 90000`
- First PTS in segment → `baseMediaDecodeTime` in tfdt
- Frame durations from PTS differences between consecutive frames

## Implementation Plan

1. Create `src/stream/mpegts.ml` — TS packet parser + PES reassembly
   - `parse_pat`: extract PMT PID from PAT
   - `parse_pmt`: extract elementary stream PIDs and stream types
   - `reassemble_pes`: collect TS payloads into PES packets per PID
   - `parse_pes_header`: extract PTS/DTS from PES header

2. Create `src/stream/h264.ml` — Annex B → length-prefix conversion
   - `split_nalus`: find NAL unit boundaries (start code search)
   - `to_length_prefix`: convert Annex B NAL → 4-byte length prefix
   - `extract_sps_pps`: find SPS/PPS from NAL stream
   - `build_avcc`: construct avcC box bytes from SPS+PPS

3. Create `src/stream/aac.ml` — ADTS → raw frame extraction
   - `parse_adts_header`: extract config + frame length
   - `strip_adts`: remove header, return raw frame
   - `build_audio_specific_config`: produce ASC bytes for esds

4. Add to `bmff_builder.ml`:
   - `avcc`: build avcC box from SPS+PPS
   - `esds`: build esds box from AudioSpecificConfig

5. Create `src/stream/demux_mpegts.ml` — the demux source
   - Takes a muxed MPEG-TS source (single URL, fetches segments)
   - Returns `Producer.video Producer.t * Producer.audio Producer.t`
   - Internally: fetch segment → demux → produce fMP4 fragments per track
   - Caches fetched segments (shared between video/audio reads)

## No OCaml Libraries Available

There are no MPEG-TS or H.264/AAC bitstream parsing libraries on opam.
All parsing must be implemented from scratch. The parsing is straightforward
(fixed-size packets, well-defined headers) and suitable for direct
byte-level manipulation similar to the existing EBML and BMFF parsers.
