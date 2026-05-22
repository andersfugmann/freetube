# DLNA / UPnP MediaRenderer — Protocol Reference

This document describes DLNA / UPnP MediaRenderer URL playback as used by
FreeTube. It covers SSDP discovery, device description XML, AVTransport SOAP,
DIDL-Lite metadata, GENA eventing, common UPnP errors, and FreeTube-observed
renderer deviations.

Reference scope: UPnP Device Architecture 2.0, SSDP, UPnP AVTransport:1/:2,
UPnP eventing, DIDL-Lite, and DLNA `protocolInfo` metadata.

---

## 0. FreeTube playback profile (current implementation)

FreeTube targets DLNA renderers with **HLS** as the only cast path.
There is no progressive-MP4 fallback today, so renderers that can't
forward an `.m3u8` to their internal media engine (notably Samsung Tizen
DMR) will fail; this is best-effort and tracked separately.

### `protocolInfo` per MIME type (see `src/dlna_client/didl_lite.ml`)

| MIME | `protocolInfo` |
| --- | --- |
| `application/vnd.apple.mpegurl` (HLS) | `http-get:*:application/vnd.apple.mpegurl:DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000` |
| `application/dash+xml` (DASH) | same OP/FLAGS pair as HLS |
| `video/mp4`, `video/webm` (progressive) | `http-get:*:<mime>:DLNA.ORG_OP=01;DLNA.ORG_FLAGS=21700000000000000000000000000000` |

Manifests get `OP=00` because HLS/DASH playback is driven by playlist
semantics, not byte-range seeks. Progressive containers keep `OP=01`
so renderers may issue `Range:` requests.

### DIDL-Lite metadata

`generate` emits `<dc:title>`, `<upnp:class>object.item.videoItem</upnp:class>`
and a `<res protocolInfo=...>` element. Optional attributes are appended
when known:

- `res@duration="H:MM:SS.mmm"` when source duration > 0
- `res@resolution="WxH"` when video stream width/height are known

`res@size` is intentionally omitted — for HLS the manifest body has no
canonical size.

### HTTP response headers for playlist & segment routes

`src/http_server/playback_handler.ml` sets, for every playlist and
segment response:

- `Content-Type: application/vnd.apple.mpegurl` (playlist) or the
  per-rendition `video/mp4` / `audio/mp4` / `video/mp2t` (segment)
- `Content-Length: <bytes>` — no chunked transfer
- `Cache-Control: no-store`
- `transferMode.dlna.org: Streaming`

---

## 1. SSDP Discovery

### Transport constants

| Field | Value |
|-------|-------|
| Protocol | UDP |
| Multicast address | `239.255.255.250` |
| Multicast port | `1900` |
| Common IPv4 TTL | `4` |
| Search request line | `M-SEARCH * HTTP/1.1` |
| Advertisement request line | `NOTIFY * HTTP/1.1` |
| Search response status | `HTTP/1.1 200 OK` |
| Line ending | CRLF (`\r\n`) |

SSDP messages use HTTP-like headers over UDP datagrams. Header names are
case-insensitive.

### Search targets

| `ST` value | Meaning |
|------------|---------|
| `ssdp:all` | All devices and services |
| `upnp:rootdevice` | Root devices only |
| `uuid:<device-uuid>` | One device by UDN UUID |
| `urn:schemas-upnp-org:device:MediaRenderer:1` | UPnP MediaRenderer devices |
| `urn:schemas-upnp-org:service:AVTransport:1` | AVTransport service v1 |
| `urn:schemas-upnp-org:service:AVTransport:2` | AVTransport service v2 |

FreeTube searches for `urn:schemas-upnp-org:service:AVTransport:1`
(`src/dlna/discovery.rs`).

### `M-SEARCH` request

```http
M-SEARCH * HTTP/1.1
HOST: 239.255.255.250:1900
MAN: "ssdp:discover"
MX: 3
ST: urn:schemas-upnp-org:device:MediaRenderer:1
USER-AGENT: FreeTube/1.0 UPnP/2.0

```

Required headers:

| Header | Value / form | Notes |
|--------|--------------|-------|
| `HOST` | `239.255.255.250:1900` | IPv4 SSDP multicast endpoint |
| `MAN` | `"ssdp:discover"` | Literal quoted value |
| `MX` | Decimal seconds | Maximum randomized response delay |
| `ST` | Search target | Device, service, UUID, `ssdp:all`, or `upnp:rootdevice` |

Common `MX` values:

| `MX` | Meaning |
|------|---------|
| `1` | Minimum common UPnP value; fast LAN probe |
| `2` | Common control-point default |
| `3` | FreeTube discovery timeout is 3 s |
| `4` | Conservative LAN probe |
| `5` | Upper end of the common UPnP discovery window |

### Unicast search

The same `M-SEARCH` format may be sent directly to a known renderer address on
UDP port `1900`.

```http
M-SEARCH * HTTP/1.1
HOST: 192.0.2.50:1900
MAN: "ssdp:discover"
MX: 1
ST: urn:schemas-upnp-org:service:AVTransport:1

```

Empirically observed (FreeTube): multicast discovery is unreliable on some LANs
and LG webOS devices. Unicast `M-SEARCH` directly to the renderer's UDP port
`1900` works when multicast responses are absent.

### Search response

```http
HTTP/1.1 200 OK
CACHE-CONTROL: max-age=1800
DATE: Sat, 01 Feb 2025 12:00:00 GMT
EXT:
LOCATION: http://192.0.2.50:1518/rootDesc.xml
SERVER: Linux/5.4 UPnP/1.0 LG-WebOS/7.0
ST: urn:schemas-upnp-org:service:AVTransport:1
USN: uuid:7f0d5a20-1111-2222-3333-444455556666::urn:schemas-upnp-org:service:AVTransport:1
BOOTID.UPNP.ORG: 17
CONFIGID.UPNP.ORG: 1
SEARCHPORT.UPNP.ORG: 1900

```

| Header | Required | Meaning |
|--------|----------|---------|
| `CACHE-CONTROL` | Yes | Advertisement lifetime, usually `max-age=<seconds>` |
| `EXT` | Yes | Empty SSDP extension acknowledgement |
| `LOCATION` | Yes | Device description XML URL |
| `SERVER` | Yes | OS/version, UPnP version, product/version |
| `ST` | Yes | Search target matched by response |
| `USN` | Yes | Unique service/device name |
| `DATE` | Optional | Response timestamp |
| `BOOTID.UPNP.ORG` | UDA 1.1/2.0 | Boot instance identifier |
| `CONFIGID.UPNP.ORG` | UDA 1.1/2.0 | Device description configuration version |
| `SEARCHPORT.UPNP.ORG` | UDA 1.1/2.0 | Unicast SSDP search port |

`USN` forms:

| Target | Example |
|--------|---------|
| Root device | `uuid:<udn>::upnp:rootdevice` |
| Device type | `uuid:<udn>::urn:schemas-upnp-org:device:MediaRenderer:1` |
| Service type | `uuid:<udn>::urn:schemas-upnp-org:service:AVTransport:1` |
| UUID only | `uuid:<udn>` |

### `ssdp:alive` notification

```http
NOTIFY * HTTP/1.1
HOST: 239.255.255.250:1900
CACHE-CONTROL: max-age=1800
LOCATION: http://192.0.2.50:1518/rootDesc.xml
NT: urn:schemas-upnp-org:device:MediaRenderer:1
NTS: ssdp:alive
SERVER: Linux/5.4 UPnP/1.0 LG-WebOS/7.0
USN: uuid:7f0d5a20-1111-2222-3333-444455556666::urn:schemas-upnp-org:device:MediaRenderer:1
BOOTID.UPNP.ORG: 17
CONFIGID.UPNP.ORG: 1

```

| Header | Value |
|--------|-------|
| `HOST` | `239.255.255.250:1900` |
| `NT` | Notification target; same namespace as `ST` |
| `NTS` | `ssdp:alive` |
| `USN` | Unique service/device name |
| `LOCATION` | Device description URL |
| `CACHE-CONTROL` | `max-age=<seconds>` |
| `SERVER` | Product token |

### `ssdp:byebye` notification

```http
NOTIFY * HTTP/1.1
HOST: 239.255.255.250:1900
NT: urn:schemas-upnp-org:service:AVTransport:1
NTS: ssdp:byebye
USN: uuid:7f0d5a20-1111-2222-3333-444455556666::urn:schemas-upnp-org:service:AVTransport:1
BOOTID.UPNP.ORG: 17
CONFIGID.UPNP.ORG: 1

```

`ssdp:byebye` removes the matching `USN` from a control-point cache.
`LOCATION`, `CACHE-CONTROL`, and `SERVER` are not required.

### FreeTube discovery parameters

| Parameter | Value |
|-----------|-------|
| Search target | `urn:schemas-upnp-org:service:AVTransport:1` |
| Discovery interval | 30 s |
| Discovery timeout | 3 s |
| Device ID | UPnP UDN string |
| Profile inputs | `manufacturer`, `modelName` |

---

## 2. Device Description XML

### Fetch

The SSDP `LOCATION` URL is fetched with HTTP `GET`.

```http
GET /rootDesc.xml HTTP/1.1
Host: 192.0.2.50:1518
Accept: text/xml, application/xml
User-Agent: FreeTube/1.0 UPnP/2.0

```

### Description document shape

```xml
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion>
    <major>1</major>
    <minor>0</minor>
  </specVersion>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>Living Room TV</friendlyName>
    <manufacturer>LG Electronics</manufacturer>
    <modelName>webOS TV</modelName>
    <UDN>uuid:7f0d5a20-1111-2222-3333-444455556666</UDN>
    <iconList>
      <icon>
        <mimetype>image/png</mimetype>
        <width>120</width>
        <height>120</height>
        <depth>24</depth>
        <url>/icon.png</url>
      </icon>
    </iconList>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
        <SCPDURL>/AVTransport/uuid:7f0d5a20-1111-2222-3333-444455556666/scpd.xml</SCPDURL>
        <controlURL>/AVTransport/uuid:7f0d5a20-1111-2222-3333-444455556666/control.xml</controlURL>
        <eventSubURL>/AVTransport/uuid:7f0d5a20-1111-2222-3333-444455556666/event.xml</eventSubURL>
      </service>
    </serviceList>
  </device>
</root>
```

### Root elements

| Element | Required | Meaning |
|---------|----------|---------|
| `<root>` | Yes | Document root; namespace `urn:schemas-upnp-org:device-1-0` |
| `<specVersion>` | Yes | UPnP device description version |
| `<URLBase>` | Optional | Base URL for relative URLs |
| `<device>` | Yes | Root device object |

### Device elements

| Element | Required | Meaning |
|---------|----------|---------|
| `<deviceType>` | Yes | Device type URN |
| `<friendlyName>` | Yes | Human display name |
| `<manufacturer>` | Yes | Manufacturer string |
| `<manufacturerURL>` | Optional | Manufacturer URL |
| `<modelDescription>` | Optional | Model description |
| `<modelName>` | Yes | Model string |
| `<modelNumber>` | Optional | Model number |
| `<modelURL>` | Optional | Model URL |
| `<serialNumber>` | Optional | Serial number |
| `<UDN>` | Yes | Unique Device Name, `uuid:<uuid>` |
| `<UPC>` | Optional | Universal Product Code |
| `<iconList>` | Optional | Device icons |
| `<serviceList>` | Required for control | Service list |
| `<deviceList>` | Optional | Embedded devices |
| `<presentationURL>` | Optional | Browser UI URL |

### Icon elements

| Element | Meaning |
|---------|---------|
| `<mimetype>` | Image MIME type |
| `<width>` | Pixel width |
| `<height>` | Pixel height |
| `<depth>` | Color depth in bits |
| `<url>` | Absolute or relative icon URL |

### Service elements

| Element | Required | Meaning |
|---------|----------|---------|
| `<serviceType>` | Yes | Service type URN |
| `<serviceId>` | Yes | Service ID URN |
| `<SCPDURL>` | Yes | Service Control Protocol Description URL |
| `<controlURL>` | Yes | SOAP action endpoint |
| `<eventSubURL>` | Yes | GENA event subscription endpoint |

Common MediaRenderer services:

| Service | Service type |
|---------|--------------|
| AVTransport | `urn:schemas-upnp-org:service:AVTransport:1` or `:2` |
| RenderingControl | `urn:schemas-upnp-org:service:RenderingControl:1` |
| ConnectionManager | `urn:schemas-upnp-org:service:ConnectionManager:1` |

FreeTube requires AVTransport; absence is surfaced as `NoAvTransport`.

### URL resolution

| URL form | Resolution |
|----------|------------|
| Absolute `http://host/path` | Used as-is |
| Absolute-path `/path` | Scheme and authority from `<URLBase>` if present, else from `LOCATION` |
| Relative-path `path` | Resolved against `<URLBase>` if present, else against the directory of `LOCATION` |
| Empty path | Invalid for `SCPDURL`, `controlURL`, and `eventSubURL` |

Examples with `LOCATION = http://192.0.2.50:1518/rootDesc.xml` and no
`URLBase`:

| Input | Resolved URL |
|-------|--------------|
| `/AVTransport/control.xml` | `http://192.0.2.50:1518/AVTransport/control.xml` |
| `AVTransport/control.xml` | `http://192.0.2.50:1518/AVTransport/control.xml` |
| `http://192.0.2.50:49152/upnp/control/AVTransport1` | unchanged |

Empirically observed (FreeTube): LG webOS MediaRenderer descriptions may be
served from a non-standard HTTP port such as `1518`, while SSDP search still
uses UDP port `1900`.

---

## 3. UPnP AVTransport Service

### Service types

| Version | Service type |
|---------|--------------|
| AVTransport:1 | `urn:schemas-upnp-org:service:AVTransport:1` |
| AVTransport:2 | `urn:schemas-upnp-org:service:AVTransport:2` |

FreeTube currently discovers and controls `AVTransport:1`.

### SOAP HTTP transport

| Field | Value |
|-------|-------|
| Method | `POST` |
| Request target | Resolved `controlURL` |
| `Content-Type` | `text/xml; charset="utf-8"` |
| `SOAPACTION` | `"<serviceType>#<ActionName>"` |
| SOAP namespace | `http://schemas.xmlsoap.org/soap/envelope/` |
| SOAP encoding style | `http://schemas.xmlsoap.org/soap/encoding/` |
| Success status | `HTTP/1.1 200 OK` |
| UPnP action error status | Usually `HTTP/1.1 500 Internal Server Error` |

`SOAPACTION` includes literal double quotes.

### SOAP envelope structure

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope
  xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
  s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:ActionName xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
    </u:ActionName>
  </s:Body>
</s:Envelope>
```

### Action reference

| Action | Purpose | FreeTube use |
|--------|---------|--------------|
| `SetAVTransportURI` | Set current media URL and metadata | Start playback |
| `Play` | Start/resume playback | Start playback |
| `Pause` | Pause playback | Reference only |
| `Stop` | Stop playback | Stop/replace session |
| `Seek` | Seek within media | Reference only |
| `GetTransportInfo` | Read coarse state | Reference only |
| `GetPositionInfo` | Read position state | `/api/dlna/status` |
| `GetMediaInfo` | Read current media metadata | Reference only |

### `SetAVTransportURI`

| Argument | Direction | Type | Required | Notes |
|----------|-----------|------|----------|-------|
| `InstanceID` | in | `ui4` | Yes | Usually `0` |
| `CurrentURI` | in | `string` | Yes | Media URL or manifest URL |
| `CurrentURIMetaData` | in | `string` | Yes | DIDL-Lite XML escaped as XML text |

Return values: none.

```http
POST /AVTransport/uuid:7f0d5a20-1111-2222-3333-444455556666/control.xml HTTP/1.1
Host: 192.0.2.50:1518
Content-Type: text/xml; charset="utf-8"
SOAPACTION: "urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI"
Content-Length: 1450

<?xml version="1.0" encoding="utf-8"?>
<s:Envelope
  xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
  s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <CurrentURI>http://192.0.2.10:5544/session/8df4/manifest.mpd</CurrentURI>
      <CurrentURIMetaData>&lt;DIDL-Lite xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/&quot; xmlns:dc=&quot;http://purl.org/dc/elements/1.1/&quot; xmlns:upnp=&quot;urn:schemas-upnp-org:metadata-1-0/upnp/&quot;&gt;&lt;item id=&quot;0&quot; parentID=&quot;0&quot; restricted=&quot;1&quot;&gt;&lt;dc:title&gt;Example Video&lt;/dc:title&gt;&lt;upnp:class&gt;object.item.videoItem&lt;/upnp:class&gt;&lt;res protocolInfo=&quot;http-get:*:application/dash+xml:DLNA.ORG_FLAGS=01700000000000000000000000000000&quot;&gt;http://192.0.2.10:5544/session/8df4/manifest.mpd&lt;/res&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</CurrentURIMetaData>
    </u:SetAVTransportURI>
  </s:Body>
</s:Envelope>
```

Success response:

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
  <s:Body>
    <u:SetAVTransportURIResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1" />
  </s:Body>
</s:Envelope>
```

Observed behaviours:

| Behaviour | Notes |
|-----------|-------|
| `InstanceID` | Most MediaRenderer devices expose only instance `0` |
| Empty metadata | Some devices accept it; LG webOS may reject it |
| Manifest MIME mismatch | Often fails as UPnP error `714` |
| Unescaped metadata | Fails XML parsing before AVTransport action dispatch |

Empirically observed (FreeTube): LG webOS returns UPnP error `714`
(`Illegal MIME-type`) when `CurrentURIMetaData` is empty. DIDL-Lite is
mandatory for these renderers.

### `Play`

| Argument | Direction | Type | Required | Notes |
|----------|-----------|------|----------|-------|
| `InstanceID` | in | `ui4` | Yes | Usually `0` |
| `Speed` | in | `string` | Yes | Common value: `1` |

Return values: none.

```http
POST /AVTransport/uuid:7f0d5a20-1111-2222-3333-444455556666/control.xml HTTP/1.1
Host: 192.0.2.50:1518
Content-Type: text/xml; charset="utf-8"
SOAPACTION: "urn:schemas-upnp-org:service:AVTransport:1#Play"
Content-Length: 354

<?xml version="1.0" encoding="utf-8"?>
<s:Envelope
  xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
  s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <Speed>1</Speed>
    </u:Play>
  </s:Body>
</s:Envelope>
```

| State before action | Common result |
|---------------------|---------------|
| `STOPPED` with URI set | Playback begins |
| `PAUSED_PLAYBACK` | Playback resumes |
| No current URI | Error `701` or `716` |
| Unsupported speed | Error `717` on devices that validate speed |

### `Pause`

| Argument | Direction | Type | Required |
|----------|-----------|------|----------|
| `InstanceID` | in | `ui4` | Yes |

Return values: none.

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope
  xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
  s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Pause xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
    </u:Pause>
  </s:Body>
</s:Envelope>
```

| Behaviour | Notes |
|-----------|-------|
| `PLAYING` to `PAUSED_PLAYBACK` | Common |
| Unsupported by live streams | Error `701` or `501` |
| Already stopped | Error `701` common |

### `Stop`

| Argument | Direction | Type | Required |
|----------|-----------|------|----------|
| `InstanceID` | in | `ui4` | Yes |

Return values: none.

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope
  xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
  s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Stop xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
    </u:Stop>
  </s:Body>
</s:Envelope>
```

FreeTube sends `Stop` before replacing or clearing the active DLNA session.

### `Seek`

| Argument | Direction | Type | Required | Notes |
|----------|-----------|------|----------|-------|
| `InstanceID` | in | `ui4` | Yes | Usually `0` |
| `Unit` | in | `string` | Yes | Seek unit |
| `Target` | in | `string` | Yes | Unit-specific target |

Common `Unit` values:

| Unit | Target form |
|------|-------------|
| `REL_TIME` | `HH:MM:SS` or `HH:MM:SS.mmm` relative time |
| `ABS_TIME` | `HH:MM:SS` or `HH:MM:SS.mmm` absolute time |
| `TRACK_NR` | Decimal track number |
| `REL_COUNT` | Decimal counter |
| `ABS_COUNT` | Decimal counter |

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope
  xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
  s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Seek xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <Unit>REL_TIME</Unit>
      <Target>00:10:30</Target>
    </u:Seek>
  </s:Body>
</s:Envelope>
```

| Behaviour | Notes |
|-----------|-------|
| `REL_TIME` | Most useful for video-on-demand renderers |
| DASH/HLS seeking | Renderer may re-request manifest and segments |
| Unsupported unit | Error `710` |
| Invalid target | Error `711` |

### `GetTransportInfo`

| Argument | Direction | Type | Required |
|----------|-----------|------|----------|
| `InstanceID` | in | `ui4` | Yes |

Return values:

| Return value | Type | Common values |
|--------------|------|---------------|
| `CurrentTransportState` | `string` | `STOPPED`, `PLAYING`, `PAUSED_PLAYBACK`, `TRANSITIONING`, `NO_MEDIA_PRESENT` |
| `CurrentTransportStatus` | `string` | `OK`, `ERROR_OCCURRED` |
| `CurrentSpeed` | `string` | `1`, `0` |

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope
  xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
  s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:GetTransportInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
    </u:GetTransportInfo>
  </s:Body>
</s:Envelope>
```

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
  <s:Body>
    <u:GetTransportInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <CurrentTransportState>PLAYING</CurrentTransportState>
      <CurrentTransportStatus>OK</CurrentTransportStatus>
      <CurrentSpeed>1</CurrentSpeed>
    </u:GetTransportInfoResponse>
  </s:Body>
</s:Envelope>
```

### `GetPositionInfo`

| Argument | Direction | Type | Required |
|----------|-----------|------|----------|
| `InstanceID` | in | `ui4` | Yes |

Return values:

| Return value | Type | Meaning |
|--------------|------|---------|
| `Track` | `ui4` | Current track number; often `1` |
| `TrackDuration` | `string` | `HH:MM:SS` or `00:00:00` if unknown |
| `TrackMetaData` | `string` | DIDL-Lite or empty |
| `TrackURI` | `string` | Current media URL |
| `RelTime` | `string` | Relative playback time |
| `AbsTime` | `string` | Absolute playback time or same as `RelTime` |
| `RelCount` | `i4` | Relative counter or `2147483647` when unsupported |
| `AbsCount` | `i4` | Absolute counter or `2147483647` when unsupported |

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope
  xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
  s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:GetPositionInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
    </u:GetPositionInfo>
  </s:Body>
</s:Envelope>
```

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
  <s:Body>
    <u:GetPositionInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <Track>1</Track>
      <TrackDuration>00:03:42</TrackDuration>
      <TrackMetaData></TrackMetaData>
      <TrackURI>http://192.0.2.10:5544/session/8df4/manifest.mpd</TrackURI>
      <RelTime>00:01:15</RelTime>
      <AbsTime>00:01:15</AbsTime>
      <RelCount>2147483647</RelCount>
      <AbsCount>2147483647</AbsCount>
    </u:GetPositionInfoResponse>
  </s:Body>
</s:Envelope>
```

FreeTube exposes this action through `/api/dlna/status`.

### `GetMediaInfo`

| Argument | Direction | Type | Required |
|----------|-----------|------|----------|
| `InstanceID` | in | `ui4` | Yes |

Return values:

| Return value | Type | Meaning |
|--------------|------|---------|
| `NrTracks` | `ui4` | Number of tracks |
| `MediaDuration` | `string` | Duration as `HH:MM:SS` or `00:00:00` |
| `CurrentURI` | `string` | Current URI |
| `CurrentURIMetaData` | `string` | DIDL-Lite metadata |
| `NextURI` | `string` | Queued next URI |
| `NextURIMetaData` | `string` | Queued next metadata |
| `PlayMedium` | `string` | Usually `NETWORK` |
| `RecordMedium` | `string` | Usually `NOT_IMPLEMENTED` |
| `WriteStatus` | `string` | Usually `NOT_IMPLEMENTED` |

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope
  xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
  s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:GetMediaInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
    </u:GetMediaInfo>
  </s:Body>
</s:Envelope>
```

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
  <s:Body>
    <u:GetMediaInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <NrTracks>1</NrTracks>
      <MediaDuration>00:03:42</MediaDuration>
      <CurrentURI>http://192.0.2.10:5544/session/8df4/manifest.mpd</CurrentURI>
      <CurrentURIMetaData></CurrentURIMetaData>
      <NextURI></NextURI>
      <NextURIMetaData></NextURIMetaData>
      <PlayMedium>NETWORK</PlayMedium>
      <RecordMedium>NOT_IMPLEMENTED</RecordMedium>
      <WriteStatus>NOT_IMPLEMENTED</WriteStatus>
    </u:GetMediaInfoResponse>
  </s:Body>
</s:Envelope>
```

AVTransport:2 devices may expose `GetMediaInfo_Ext`; it is not required for
FreeTube URL playback.

### SOAP fault shape

```http
HTTP/1.1 500 Internal Server Error
Content-Type: text/xml; charset="utf-8"
Content-Length: 560

<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
  <s:Body>
    <s:Fault>
      <faultcode>s:Client</faultcode>
      <faultstring>UPnPError</faultstring>
      <detail>
        <UPnPError xmlns="urn:schemas-upnp-org:control-1-0">
          <errorCode>714</errorCode>
          <errorDescription>Illegal MIME-type</errorDescription>
        </UPnPError>
      </detail>
    </s:Fault>
  </s:Body>
</s:Envelope>
```

---

## 4. DIDL-Lite Metadata

### Envelope

`CurrentURIMetaData` contains a DIDL-Lite document serialized as escaped XML
text inside the SOAP request.

Unescaped DIDL-Lite:

```xml
<DIDL-Lite
  xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"
  xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"
  xmlns:dc="http://purl.org/dc/elements/1.1/">
  <item id="0" parentID="0" restricted="1">
    <dc:title>Example Video</dc:title>
    <upnp:class>object.item.videoItem</upnp:class>
    <res protocolInfo="http-get:*:application/dash+xml:DLNA.ORG_FLAGS=01700000000000000000000000000000">http://192.0.2.10:5544/session/8df4/manifest.mpd</res>
  </item>
</DIDL-Lite>
```

Escaped inside SOAP:

```xml
<CurrentURIMetaData>&lt;DIDL-Lite xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/&quot; xmlns:upnp=&quot;urn:schemas-upnp-org:metadata-1-0/upnp/&quot; xmlns:dc=&quot;http://purl.org/dc/elements/1.1/&quot;&gt;&lt;item id=&quot;0&quot; parentID=&quot;0&quot; restricted=&quot;1&quot;&gt;&lt;dc:title&gt;Example Video&lt;/dc:title&gt;&lt;upnp:class&gt;object.item.videoItem&lt;/upnp:class&gt;&lt;res protocolInfo=&quot;http-get:*:application/dash+xml:DLNA.ORG_FLAGS=01700000000000000000000000000000&quot;&gt;http://192.0.2.10:5544/session/8df4/manifest.mpd&lt;/res&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</CurrentURIMetaData>
```

### Required and common elements

| Element / attribute | Required | Meaning |
|---------------------|----------|---------|
| `DIDL-Lite` | Yes | Root metadata element |
| `xmlns` | Yes | `urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/` |
| `xmlns:upnp` | Yes | `urn:schemas-upnp-org:metadata-1-0/upnp/` |
| `xmlns:dc` | Yes | `http://purl.org/dc/elements/1.1/` |
| `item` | Yes | One media object |
| `item@id` | Yes | Object ID; often `0` |
| `item@parentID` | Yes | Parent container ID; often `0` or `-1` |
| `item@restricted` | Yes | `1` for non-editable renderer item |
| `dc:title` | Recommended | Display title |
| `upnp:class` | Recommended | UPnP object class |
| `res` | Yes | Playable resource URL |
| `res@protocolInfo` | Yes | DLNA/UPnP protocol metadata |

Common `upnp:class` values:

| Class | Meaning |
|-------|---------|
| `object.item.videoItem` | Generic video item |
| `object.item.videoItem.movie` | Movie |
| `object.item.audioItem.musicTrack` | Audio track |
| `object.item.imageItem.photo` | Photo |

FreeTube uses `object.item.videoItem`.

### `protocolInfo`

Format:

```text
<protocol>:<network>:<contentFormat>:<additionalInfo>
```

| Field | Example | Meaning |
|-------|---------|---------|
| `protocol` | `http-get` | Transfer protocol |
| `network` | `*` | Network wildcard |
| `contentFormat` | `application/dash+xml` | MIME type |
| `additionalInfo` | `DLNA.ORG_FLAGS=01700000000000000000000000000000` | Semicolon-separated DLNA parameters or `*` |

Examples:

| Media | `protocolInfo` |
|-------|----------------|
| MPEG-DASH MPD | `http-get:*:application/dash+xml:DLNA.ORG_FLAGS=01700000000000000000000000000000` |
| HLS playlist | `http-get:*:application/x-mpegURL:DLNA.ORG_FLAGS=01700000000000000000000000000000` |
| MP4 file | `http-get:*:video/mp4:DLNA.ORG_PN=AVC_MP4_MP_HD_720p_AAC;DLNA.ORG_FLAGS=01700000000000000000000000000000` |
| WebM | `http-get:*:video/webm:*` |
| FreeTube current metadata | `http-get:*:<mime_type>:*` |

### Common MIME types

| Resource | MIME type |
|----------|-----------|
| MPEG-DASH manifest | `application/dash+xml` |
| HLS playlist | `application/x-mpegURL` |
| HLS playlist alternate | `application/vnd.apple.mpegurl` |
| MPEG-4 / fMP4 | `video/mp4` |
| MPEG-TS | `video/vnd.dlna.mpeg-tts` |
| WebM | `video/webm` |
| AAC | `audio/mp4` or `audio/aac` |
| Opus in WebM | `audio/webm` |

### `DLNA.ORG_PN`

`DLNA.ORG_PN` is a DLNA media profile name. Adaptive manifest URLs are often
sent without a profile name; direct file resources more often carry one.

| `DLNA.ORG_PN` | Typical media |
|---------------|---------------|
| `AVC_MP4_MP_SD_AAC_MULT5` | H.264 MP4 SD with AAC multichannel |
| `AVC_MP4_MP_HD_720p_AAC` | H.264 MP4 HD 720p with AAC |
| `AVC_TS_MP_HD_AAC_MULT5` | H.264 MPEG-TS HD with AAC multichannel |
| `MPEG_TS_SD_EU` | MPEG-TS SD profile |
| `MP3` | MP3 audio |
| `JPEG_SM` | Small JPEG image |

Incorrect profile names can cause stricter renderers to reject otherwise
playable media.

### `DLNA.ORG_FLAGS`

`DLNA.ORG_FLAGS` is a 128-bit field serialized as 32 hexadecimal digits.
Common value:

```text
DLNA.ORG_FLAGS=01700000000000000000000000000000
```

First word `0x01700000` means:

| Bit mask | Name | Meaning |
|----------|------|---------|
| `0x01000000` | Streaming transfer mode | Streaming HTTP transfer supported |
| `0x00400000` | Background transfer mode | Background transfer mode supported |
| `0x00200000` | Connection stalling | HTTP connection stalling supported |
| `0x00100000` | DLNA v1.5 | DLNA 1.5 operation |

Other high-word flags:

| Bit mask | Name | Meaning |
|----------|------|---------|
| `0x80000000` | Sender paced | Sender controls pacing |
| `0x40000000` | Time-based seek | Time seek supported |
| `0x20000000` | Byte-based seek | Byte-range seek supported |
| `0x10000000` | Play container | DLNA play-container supported |
| `0x08000000` | S0 increasing | Normal increasing sequence parameter |
| `0x04000000` | SN increasing | Normal increasing sequence number |
| `0x02000000` | RTSP pause | RTSP pause supported |
| `0x00800000` | Interactive transfer mode | Interactive transfer supported |

### Other DLNA parameters

| Parameter | Example | Meaning |
|-----------|---------|---------|
| `DLNA.ORG_OP` | `01` | Operations flags; range/seek support |
| `DLNA.ORG_CI` | `0` | Conversion indicator; `0` not transcoded, `1` transcoded |
| `DLNA.ORG_PS` | `1` | Supported play speeds |
| `DLNA.ORG_PN` | `AVC_MP4_MP_HD_720p_AAC` | DLNA profile name |
| `DLNA.ORG_FLAGS` | `01700000000000000000000000000000` | Capability flags |

---

## 5. GENA Eventing

UPnP eventing uses HTTP methods against a service's `eventSubURL`.
AVTransport events usually carry a single `LastChange` property containing
nested XML.

### New subscription

```http
SUBSCRIBE /AVTransport/uuid:7f0d5a20-1111-2222-3333-444455556666/event.xml HTTP/1.1
Host: 192.0.2.50:1518
CALLBACK: <http://192.0.2.10:8090/upnp/events/avtransport>
NT: upnp:event
TIMEOUT: Second-1800

```

| Header | Value |
|--------|-------|
| `CALLBACK` | One or more callback URLs in angle brackets |
| `NT` | `upnp:event` |
| `TIMEOUT` | `Second-<seconds>` or `infinite` |

Success response:

```http
HTTP/1.1 200 OK
SID: uuid:0f3bdf38-7777-4444-aaaa-0123456789ab
TIMEOUT: Second-1800
SERVER: Linux/5.4 UPnP/1.0 LG-WebOS/7.0

```

### Renewal

```http
SUBSCRIBE /AVTransport/uuid:7f0d5a20-1111-2222-3333-444455556666/event.xml HTTP/1.1
Host: 192.0.2.50:1518
SID: uuid:0f3bdf38-7777-4444-aaaa-0123456789ab
TIMEOUT: Second-1800

```

Renewal uses `SID` and `TIMEOUT`; `CALLBACK` and `NT` are absent.

### Unsubscribe

```http
UNSUBSCRIBE /AVTransport/uuid:7f0d5a20-1111-2222-3333-444455556666/event.xml HTTP/1.1
Host: 192.0.2.50:1518
SID: uuid:0f3bdf38-7777-4444-aaaa-0123456789ab

```

Success response:

```http
HTTP/1.1 200 OK

```

### Notify

```http
NOTIFY /upnp/events/avtransport HTTP/1.1
Host: 192.0.2.10:8090
Content-Type: text/xml; charset="utf-8"
NT: upnp:event
NTS: upnp:propchange
SID: uuid:0f3bdf38-7777-4444-aaaa-0123456789ab
SEQ: 12
Content-Length: 980

<?xml version="1.0" encoding="utf-8"?>
<e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">
  <e:property>
    <LastChange>&lt;Event xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/AVT/&quot;&gt;&lt;InstanceID val=&quot;0&quot;&gt;&lt;TransportState val=&quot;PLAYING&quot;/&gt;&lt;TransportStatus val=&quot;OK&quot;/&gt;&lt;CurrentTrackURI val=&quot;http://192.0.2.10:5544/session/8df4/manifest.mpd&quot;/&gt;&lt;RelativeTimePosition val=&quot;00:01:15&quot;/&gt;&lt;/InstanceID&gt;&lt;/Event&gt;</LastChange>
  </e:property>
</e:propertyset>
```

Required `NOTIFY` headers:

| Header | Value |
|--------|-------|
| `NT` | `upnp:event` |
| `NTS` | `upnp:propchange` |
| `SID` | Subscription ID |
| `SEQ` | Decimal sequence number; starts at `0` |
| `Content-Type` | `text/xml; charset="utf-8"` |

### `LastChange` value

Unescaped value:

```xml
<Event xmlns="urn:schemas-upnp-org:metadata-1-0/AVT/">
  <InstanceID val="0">
    <TransportState val="PLAYING" />
    <TransportStatus val="OK" />
    <CurrentTransportActions val="Stop,Pause,Seek" />
    <CurrentTrack val="1" />
    <CurrentTrackDuration val="00:03:42" />
    <CurrentTrackURI val="http://192.0.2.10:5544/session/8df4/manifest.mpd" />
    <RelativeTimePosition val="00:01:15" />
    <AbsoluteTimePosition val="00:01:15" />
    <CurrentMediaDuration val="00:03:42" />
  </InstanceID>
</Event>
```

| Element | Attribute | Values / meaning |
|---------|-----------|------------------|
| `InstanceID` | `val` | AVTransport instance, usually `0` |
| `TransportState` | `val` | `STOPPED`, `PLAYING`, `PAUSED_PLAYBACK`, `TRANSITIONING` |
| `TransportStatus` | `val` | `OK`, `ERROR_OCCURRED` |
| `CurrentTransportActions` | `val` | Comma-separated allowed actions |
| `CurrentTrack` | `val` | Current track number |
| `CurrentTrackDuration` | `val` | Duration |
| `CurrentTrackURI` | `val` | Current resource URL |
| `RelativeTimePosition` | `val` | Relative playback time |
| `AbsoluteTimePosition` | `val` | Absolute playback time |
| `CurrentMediaDuration` | `val` | Media duration |

FreeTube does not currently rely on GENA for DLNA playback state; it queries
`GetPositionInfo` for `/api/dlna/status`.

---

## 6. UPnP Error Codes

### SOAP-level errors

| Code | Name | Meaning |
|------|------|---------|
| `401` | Invalid Action | Action name not supported by service |
| `402` | Invalid Args | Missing, unknown, or invalid action arguments |
| `404` | Invalid Var | Invalid state variable reference |
| `501` | Action Failed | Generic action failure |
| `600` | Argument Value Invalid | Argument value invalid for action |
| `601` | Argument Value Out of Range | Argument value outside allowed range |
| `602` | Optional Action Not Implemented | Optional action not implemented |
| `603` | Out of Memory | Device cannot allocate resources |
| `604` | Human Intervention Required | Device requires manual action |
| `605` | String Argument Too Long | String argument exceeds device limit |
| `606` | Action Not Authorized | Control point not authorized |

### AVTransport errors

Codes 701–718 are defined in UPnP AVTransport:1 Service (Table 2.4.4). Codes 719 and 720 are defined in UPnP ContentDirectory:1 Service (§2.7.16), not AVTransport:1; they are included here because some MediaRenderer implementations return them in AVTransport SOAP faults (Empirically observed — FreeTube).

| Code | Name | Typical trigger |
|------|------|-----------------|
| `701` | Transition not available | Action invalid in current transport state |
| `702` | No contents | No current media resource |
| `703` | Read error | Renderer cannot read resource |
| `704` | Format not supported for playback | Unsupported container, codec, or profile |
| `705` | Transport is locked | Renderer busy or locked |
| `706` | Write error | Record/write failure |
| `707` | Media protected or not writable | Protected media or write-protected resource |
| `708` | Recording format not supported | Unsupported recording format |
| `709` | Media full | Storage full |
| `710` | Seek mode not supported | Unsupported `Seek` `Unit` |
| `711` | Illegal seek target | Invalid `Seek` `Target` |
| `712` | Play mode not supported | Unsupported play mode |
| `713` | Record quality not supported | Unsupported record quality |
| `714` | Illegal MIME-type | MIME type rejected or required DIDL metadata missing |
| `715` | Content "BUSY" | Resource busy |
| `716` | Resource Not found | URL unreachable or no current resource |
| `717` | Play speed not supported | Unsupported `Play` speed |
| `718` | Invalid InstanceID | Instance ID not exposed by renderer |
| `719` | Destination resource access denied | Renderer cannot access URL or network path |
| `720` | Cannot process the request | Generic renderer-side processing failure |

FreeTube-relevant failures:

| Error | Common cause |
|-------|--------------|
| `714` | Missing DIDL-Lite metadata; wrong manifest MIME type |
| `716` | FreeTube server URL unreachable from renderer LAN |
| `718` | Renderer does not expose AVTransport instance `0` |
| `719` | Renderer denied access to advertised HTTP URL |
| `720` | Renderer rejected codec/container after accepting metadata |

---

## 7. Empirically Observed Device Deviations

These observations are not normative UPnP or DLNA requirements.

### Samsung QE43QN90AATXXC TV

Empirically observed (FreeTube):

| Property | Observation |
|----------|-------------|
| Vendor family | Samsung TV / Tizen MediaRenderer |
| `ftyp` major brand | Requires `isom` for fMP4 init segments |
| Rejected `ftyp` brand | Default `iso5` is rejected |
| AV1 | No AV1 decode support observed through DLNA renderer |
| Working video | HEVC or H.264 in fMP4 with `isom` brand |
| Working audio | AAC in fMP4 with `isom` brand |
| Working manifests | HLS fMP4; DASH/fMP4 when advertised with compatible metadata and `isom` init brand |
| FreeTube profile | Conservative Samsung profile: HLS, HEVC/H.264, AAC, `isom` container |

FreeTube source locations:

| Behaviour | Source |
|-----------|--------|
| Samsung profile selects HLS first | `src/dlna/profile.rs` |
| Samsung profile restricts video to HEVC/H.264 with `isom` | `src/dlna/profile.rs` |
| Samsung profile restricts audio to AAC with `isom` | `src/dlna/profile.rs` |
| `isom` brand patch field | `doc/api.md`, `src/pipeline/types.rs` |

### LG webOS TV (`fugtv`)

Empirically observed (FreeTube):

| Property | Observation |
|----------|-------------|
| Vendor family | LG webOS MediaRenderer |
| DASH | Supports MPEG-DASH playback directly |
| AV1 | Supports AV1 over DASH on observed device |
| Opus | Supports Opus over DASH on observed device |
| Transcoding | Not needed for AV1+Opus DASH on observed device |
| Device description port | Non-standard HTTP port observed, e.g. `1518` |
| SSDP multicast | Unreliable on some networks |
| SSDP unicast | Direct unicast `M-SEARCH` to UDP port `1900` works |
| AVTransport control path | `/AVTransport/{UDN}/control.xml` |
| Metadata | Empty `CurrentURIMetaData` can produce UPnP error `714` |

Representative control URL:

```text
http://192.0.2.50:1518/AVTransport/uuid:7f0d5a20-1111-2222-3333-444455556666/control.xml
```

Representative DASH resource metadata:

```xml
<res protocolInfo="http-get:*:application/dash+xml:DLNA.ORG_FLAGS=01700000000000000000000000000000">http://192.0.2.10:5544/session/8df4/manifest.mpd</res>
```

### Generic renderer notes

Empirically observed (FreeTube):

| Area | Compatibility note |
|------|--------------------|
| Metadata | DIDL-Lite metadata is safer than empty metadata |
| URL reachability | Renderer must reach the FreeTube server URL directly over the LAN |
| Host address | `localhost` and loopback addresses in `CurrentURI` are invalid for external renderers |
| Manifest MIME | HLS as `application/x-mpegURL`; DASH as `application/dash+xml` |
| fMP4 brand | `isom` maximizes TV compatibility |
| Instance ID | `0` is standard for single-instance renderers |

---

## 8. FreeTube DLNA Control Summary

### Playback sequence

| Step | Protocol object | FreeTube source |
|------|-----------------|-----------------|
| Discover renderer | SSDP `M-SEARCH` for `AVTransport:1` | `src/dlna/discovery.rs` |
| Fetch device description | HTTP `GET` on `LOCATION` | UPnP client library |
| Detect profile | `manufacturer`, `modelName` | `src/dlna/profile.rs` |
| Create streaming session | Device preferences and profile | `src/routes/dlna.rs`, `src/session.rs` |
| Select manifest URL | HLS or DASH from `DeviceProfile.preferred_manifest()` | `src/routes/dlna.rs` |
| Build DIDL-Lite metadata | Title, MIME type, resource URL | `src/dlna/session.rs` |
| Set resource | SOAP `SetAVTransportURI` | `src/dlna/session.rs` |
| Start playback | SOAP `Play`, `Speed=1` | `src/dlna/session.rs` |
| Stop playback | SOAP `Stop` | `src/dlna/session.rs` |
| Query status | SOAP `GetPositionInfo` | `src/dlna/session.rs`, `src/routes/dlna.rs` |

### FreeTube DIDL-Lite shape

| Field | Value |
|-------|-------|
| `item@id` | `0` |
| `item@parentID` | `-1` |
| `item@restricted` | `1` |
| `dc:title` | Playback title |
| `upnp:class` | `object.item.videoItem` |
| `res@protocolInfo` | `http-get:*:<mime_type>:*` |
| `res` text | FreeTube session manifest URL |

### FreeTube MIME selection

| Manifest URL suffix | MIME type in DIDL-Lite |
|---------------------|------------------------|
| `.mpd` | `application/dash+xml` |
| Other DLNA playback URL | `application/x-mpegURL` |

### Built-in device profiles

| Detected device | Manifest preference | Video capability preference | Audio capability preference |
|-----------------|---------------------|-----------------------------|-----------------------------|
| Samsung | HLS | HEVC:`isom`, H.264:`isom` | AAC:`isom` |
| LG / unknown / other | HLS, then DASH | AV1, VP9, HEVC, H.264 | AAC, Opus |

Device preferences seeded from the profile are authoritative at play time for
codec and dynamic-range policy. The profile remains authoritative for manifest
format and DIDL-Lite MIME choice.

---

## 9. Header Reference

### SSDP headers

| Header | Message | Required | Example |
|--------|---------|----------|---------|
| `HOST` | `M-SEARCH`, `NOTIFY` | Yes | `239.255.255.250:1900` |
| `MAN` | `M-SEARCH` | Yes | `"ssdp:discover"` |
| `MX` | `M-SEARCH` | Yes | `3` |
| `ST` | `M-SEARCH`, response | Yes | `urn:schemas-upnp-org:service:AVTransport:1` |
| `USN` | response, `NOTIFY` | Yes | `uuid:<udn>::<target>` |
| `LOCATION` | response, alive `NOTIFY` | Yes | `http://host:port/rootDesc.xml` |
| `CACHE-CONTROL` | response, alive `NOTIFY` | Yes | `max-age=1800` |
| `SERVER` | response, alive `NOTIFY` | Yes | `Linux/5.4 UPnP/1.0 Product/1.0` |
| `EXT` | response | Yes | empty |
| `NT` | `NOTIFY` | Yes | `upnp:rootdevice` |
| `NTS` | `NOTIFY` | Yes | `ssdp:alive`, `ssdp:byebye`, `ssdp:update` |
| `BOOTID.UPNP.ORG` | response, `NOTIFY` | UDA 1.1/2.0 | `17` |
| `CONFIGID.UPNP.ORG` | response, `NOTIFY` | UDA 1.1/2.0 | `1` |

### SOAP headers

| Header | Required | Example |
|--------|----------|---------|
| `Host` | Yes | `192.0.2.50:1518` |
| `Content-Type` | Yes | `text/xml; charset="utf-8"` |
| `SOAPACTION` | Yes | `"urn:schemas-upnp-org:service:AVTransport:1#Play"` |
| `Content-Length` | Yes when body present | `354` |
| `User-Agent` | Optional | `FreeTube/1.0 UPnP/2.0` |

### GENA headers

| Header | Message | Required | Example |
|--------|---------|----------|---------|
| `CALLBACK` | New `SUBSCRIBE` | Yes | `<http://192.0.2.10:8090/upnp/events>` |
| `NT` | New `SUBSCRIBE`, `NOTIFY` | Yes | `upnp:event` |
| `NTS` | `NOTIFY` | Yes | `upnp:propchange` |
| `TIMEOUT` | `SUBSCRIBE`, response | Yes | `Second-1800` |
| `SID` | Renewal, `UNSUBSCRIBE`, response, `NOTIFY` | Yes | `uuid:<subscription-id>` |
| `SEQ` | `NOTIFY` | Yes | `0` |
| `Content-Type` | `NOTIFY` | Yes | `text/xml; charset="utf-8"` |

---

## 10. Wire-Format Constants

| Constant | Value |
|----------|-------|
| SSDP multicast IPv4 | `239.255.255.250` |
| SSDP UDP port | `1900` |
| SSDP request line | `M-SEARCH * HTTP/1.1` |
| SSDP notify line | `NOTIFY * HTTP/1.1` |
| SSDP discover marker | `MAN: "ssdp:discover"` |
| Root device target | `upnp:rootdevice` |
| All target | `ssdp:all` |
| MediaRenderer device type | `urn:schemas-upnp-org:device:MediaRenderer:1` |
| AVTransport v1 service type | `urn:schemas-upnp-org:service:AVTransport:1` |
| AVTransport v2 service type | `urn:schemas-upnp-org:service:AVTransport:2` |
| SOAP envelope namespace | `http://schemas.xmlsoap.org/soap/envelope/` |
| SOAP encoding style | `http://schemas.xmlsoap.org/soap/encoding/` |
| UPnP control error namespace | `urn:schemas-upnp-org:control-1-0` |
| DIDL-Lite namespace | `urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/` |
| UPnP metadata namespace | `urn:schemas-upnp-org:metadata-1-0/upnp/` |
| Dublin Core namespace | `http://purl.org/dc/elements/1.1/` |
| AVTransport LastChange namespace | `urn:schemas-upnp-org:metadata-1-0/AVT/` |
| GENA property namespace | `urn:schemas-upnp-org:event-1-0` |
| GENA event notification type | `upnp:event` |
| GENA property-change marker | `upnp:propchange` |
| Normal AVTransport instance | `0` |
| Normal playback speed | `1` |
| Common DLNA flags | `01700000000000000000000000000000` |
| Samsung-compatible fMP4 brand | `isom` |
