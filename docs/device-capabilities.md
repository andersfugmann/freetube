# Device Capabilities & Streaming Restrictions

Discovered renderers (via DLNA SSDP or AirPlay mDNS) have varying codec,
container, and manifest support.  The session layer must select the right
delivery format per-device.

## Known device profiles

| Device | Protocol | Manifest | Containers | Video Codecs | Audio Codecs |
|--------|----------|----------|------------|--------------|--------------|
| Apple TV 4K | AirPlay | HLS (fMP4) | isom (fMP4) | HEVC, VP9, H.264 | AAC |
| Samsung TV (Tizen) | DLNA | DASH or HLS | isom (fMP4), WebM | AV1, VP9, HEVC, H.264 | AAC, Opus |
| LG TV (webOS) | DLNA | HLS | isom (fMP4) | HEVC, VP9, H.264 | AAC |
| Generic DLNA | DLNA | HLS | isom (fMP4) | HEVC, H.264 | AAC |

## Key constraints

- **Apple TV**: Cannot decode AV1. Rejects HEVC Main 10 with PQ/smpte2084
  transfer characteristics — must convert to 8-bit bt709. VP9 passthrough works
  in fMP4 HLS containers.

- **Samsung TV**: Plays everything natively via its internal YouTube app (DASH).
  DLNA SetAVTransportURI can accept both HLS and DASH manifest URLs. Supports
  AV1 10-bit HDR10, VP9, HEVC with PQ. Only rejects H.264 at extreme bitrates
  (>100 Mbps).

- **LG TV**: More restricted. WebOS DLNA renderer typically only accepts HLS
  with isom (fMP4) container. Does not reliably support DASH manifests via DLNA.
  Codec support: HEVC, VP9, H.264. No AV1 on older models.

- **Generic/Unknown DLNA**: Safest bet is HLS with isom container, HEVC or
  H.264 video, AAC audio. Most DLNA renderers support this combination.

## Container note

For HLS delivery, the `ftyp` box major brand must be `isom` (not `dash` or
`mp42`) for maximum player compatibility. YouTube CDN already serves fMP4 with
`isom` brand, so passthrough segments are compatible. When transcoding, FFmpeg's
`-brand isom` flag ensures correct output.

## Discovery → capability mapping

The DLNA discovery module must:
1. Identify the device type from UPnP device description (modelName, manufacturer)
2. Map to a `DeviceProfile` that specifies supported manifest format, codecs, and container
3. Pass the profile to SessionManager when creating a playback session
