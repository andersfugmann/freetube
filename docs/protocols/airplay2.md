# AirPlay 2 HLS URL Playback Protocol Reference

Reference for the AirPlay 2 subset used by FreeTube to start HLS URL playback on Apple TV.

Scope: discovery, HAP pairing, HAP transport, RTSP, event channels, MRP DataStream, playback commands, timing, and HLS constraints.

## Status labels

| Label | Meaning |
|---|---|
| Spec | Defined by an RFC, HAP, DNS-SD, HLS, NTP, binary plist, protobuf, or RTSP convention. |
| Empirically observed (FreeTube) | Behavior required by Apple TV/tvOS in FreeTube testing and encoded in this repository. Not asserted as Apple-spec mandated. |
| Current FreeTube | Behavior in `src/airplay/*` at this revision. |

## 1. Discovery

| Field | Value |
|---|---|
| Service type | `_airplay._tcp.local.` |
| Discovery protocols | mDNS RFC 6762, DNS-SD RFC 6763 |
| Records consumed | SRV, TXT, A/AAAA |
| Default RTSP port | SRV target port; commonly `7000` |

### TXT fields

| TXT key | Size / format | Meaning |
|---|---:|---|
| `fn` | UTF-8 string | Friendly name. FreeTube display name source. |
| `model` | UTF-8 string | Device model; `AppleTV*` identifies Apple TV. |
| `manufacturer` | UTF-8 string | Manufacturer; used only for generic device classification. |
| `deviceid` | MAC text | Device identifier. |
| `features` | Hex bitmask, often two comma-separated words | Receiver feature flags. |
| `flags` | Hex integer | Receiver status flags. |
| `pk` | 32 bytes as 64 hex chars | Receiver Ed25519 public key advertised by AirPlay. |
| `pi` | UUID text | Pairing identifier. |
| `srcvers` | Version string | AirPlay source/protocol version. |

### Address selection

| Priority | Address class | Reason |
|---:|---|---|
| 1 | IPv4 | Empirically observed (FreeTube): broadest Apple TV compatibility. |
| 2 | IPv6 global or ULA | Used when IPv4 unavailable. |
| 3 | IPv6 link-local `fe80::/10` | Last resort; interface scope handling is fragile. |

## 2. TLV8

| Offset | Size | Field | Encoding |
|---:|---:|---|---|
| 0 | 1 | Tag | Unsigned byte |
| 1 | 1 | Length | Unsigned byte, `0..255` |
| 2 | Length | Value | Raw bytes |

| Rule | Value |
|---|---|
| Fragmentation | Values over 255 bytes are emitted as consecutive records with the same tag. |
| Reassembly | Decode concatenates same-tag fragments in encounter order. |
| Truncation | Current FreeTube decoder stops at a truncated record. |

### HAP TLV tags used

| Name | Tag | Pair-setup | Pair-verify |
|---|---:|---|---|
| Method | `0x00` | M1 | no |
| Identifier | `0x01` | M5 plaintext | M2/M3 encrypted plaintext |
| Salt | `0x02` | M2 | no |
| PublicKey | `0x03` | M2, M3, M5 plaintext, M6 plaintext | M1, M2 |
| Proof | `0x04` | M3, M4 | no |
| EncryptedData | `0x05` | M5, M6 | M2, M3 |
| SequenceNum | `0x06` | M1-M6 | M1-M4 |
| Error | `0x07` | error responses | error responses |
| Signature | `0x0a` | M5 plaintext | M2/M3 encrypted plaintext |

## 3. HAP pair-setup

Purpose: one-time PIN pairing and long-term Ed25519 credential exchange.

| Property | Value |
|---|---|
| Transport | Plain TCP to AirPlay SRV port. |
| HTTP path | `/pair-pin-start`, then `/pair-setup`. |
| Persistent connection | M1 through M6 use one TCP connection. |
| Required header | `X-Apple-HKP: 3` on `/pair-setup`. |
| Pair-setup user-agent | `AirPlay/320.20` in Current FreeTube. |
| PIN request user-agent | `MediaControl/1.0` in Current FreeTube. |
| Content-Type | `application/octet-stream`. |
| SRP group | 3072-bit MODP, RFC 5054 `G3072`. |
| SRP hash | SHA-512. |
| SRP username | `Pair-Setup`. |
| SRP password | 4-digit PIN as ASCII/UTF-8 string. |
| Client SRP secret | 48 random bytes in Current FreeTube. |

### Pair-setup flow

| Step | Direction | Request / response | TLV body |
|---|---|---|---|
| PIN | Controller to receiver | `POST /pair-pin-start` | empty |
| M1 | Controller to receiver | `POST /pair-setup` | `Method=0x00`, `SequenceNum=0x01` |
| M2 | Receiver to controller | response | `SequenceNum=0x02`, `Salt`, `PublicKey` |
| M3 | Controller to receiver | `POST /pair-setup` | `SequenceNum=0x03`, `PublicKey=A`, `Proof=M1` |
| M4 | Receiver to controller | response | `SequenceNum=0x04`, `Proof=M2` |
| M5 | Controller to receiver | `POST /pair-setup` | `SequenceNum=0x05`, `EncryptedData` |
| M6 | Receiver to controller | response | `SequenceNum=0x06`, `EncryptedData` |

### SRP proof details

| Item | Value |
|---|---|
| Client proof | `SHA512(SHA512(N) XOR SHA512(g) || SHA512(I) || s || A || B || K)` |
| Server proof | `SHA512(A || client_proof || K)` |
| `N` | 3072-bit MODP modulus from RFC 5054 §3 (`G3072`). Must be the 3072-bit group; the 2048-bit RFC 3526 group 14 will silently produce a wrong `A` and fail M4 with TLV error `0x02`. |
| `g` in proof XOR | Minimal big-endian generator bytes; for `g=5`, one byte `0x05`. Do **not** pad `g` to 384 bytes. |
| `I` (username) | The literal ASCII string `Pair-Setup`. |
| `s` (salt) | Passed as the raw bytes received from the receiver. |
| `A` in proof | Client public key as **minimal big-endian bytes** (leading zero bytes trimmed), matching `int_to_bytes` in `srptools`. |
| `B` in proof | Server public key as minimal big-endian bytes (leading zero bytes trimmed). |
| `K` | `SHA512(S)` where `S` is the SRP premaster secret encoded as **minimal big-endian bytes** (no leading-zero padding). |
| `u` and `k` | Computed using RFC 5054 padding: `u = SHA512(PAD(A) || PAD(B))`, `k = SHA512(PAD(N) || PAD(g))`, where `PAD(x)` zero-pads to 384 bytes. |
| Premaster `S` | `S = (B - k·g^x)^(a + u·x) mod N`. The integer value is used directly; only the input to `SHA512(S)` for `K` is converted to minimal big-endian bytes. |
| Client private `a` | 48 random bytes in Current FreeTube. |

Compatibility note: the byte-level layout above matches Python `srptools` (the library `pyatv` uses). FreeTube's `srp.ml` is verified byte-for-byte against `srptools` reference vectors via inline tests (A, K, M1).

Key takeaways for any reimplementation:
- Two distinct byte conventions coexist in HAP SRP: **padded to N's length** for `u`, `k`, and the modular arithmetic; **minimal big-endian** for the proof inputs (`A`, `B`, `s`, `g`) and for the input to `K = SHA512(S)`.
- Mixing the two (e.g. padding `S` before hashing for `K`, or padding `g` in the proof XOR) yields a valid-looking M3 that the receiver rejects with TLV error `0x02` (kTLVError_Authentication) and invalidates the PIN.

### M5 encrypted payload

| Item | Value |
|---|---|
| AEAD | ChaCha20-Poly1305 (RFC 8439) |
| Key | HKDF-SHA512 (RFC 5869) from SRP `K`; see labels below. |
| Nonce | 12 bytes: four zero bytes, then ASCII `PS-Msg05`. |
| AAD | empty |
| Plaintext TLV | `Identifier`, `PublicKey`, `Signature` |
| Signature material | `controller_sign_material || controller_pairing_id || controller_ed25519_public_key` |

### M6 encrypted payload

| Item | Value |
|---|---|
| AEAD | ChaCha20-Poly1305 (RFC 8439) |
| Key | Same pair-setup encryption key as M5. |
| Nonce | 12 bytes: four zero bytes, then ASCII `PS-Msg06`. |
| AAD | empty |
| Plaintext TLV field consumed | receiver `PublicKey`, 32-byte Ed25519 LTPK. |

### Pair-setup HKDF labels

| Output | Salt | Info | Size |
|---|---|---|---:|
| M5/M6 encryption key | `Pair-Setup-Encrypt-Salt` | `Pair-Setup-Encrypt-Info` | 32 bytes |
| Controller signing material | `Pair-Setup-Controller-Sign-Salt` | `Pair-Setup-Controller-Sign-Info` | 32 bytes |

### Stored credentials

| Field | Size / format | Meaning |
|---|---:|---|
| `device_id` | string | FreeTube device id; static ids may map to mDNS ids. |
| `controller_pairing_id` | 32 uppercase hex chars in Current FreeTube | HAP controller identifier. |
| `controller_ltpk_hex` | 64 hex chars | Controller Ed25519 public key. |
| `controller_ltsk_hex` | 64 hex chars | Controller Ed25519 private seed. |
| `receiver_ltpk_hex` | 64 hex chars | Apple TV Ed25519 public key from M6. |

## 4. HAP pair-verify

Purpose: per-TCP-connection authentication and X25519 shared-secret establishment.

| Property | Value |
|---|---|
| Transport | Plain TCP until M4 response body ends; HAP encryption after M4. |
| HTTP path | `/pair-verify`. |
| Required header | `X-Apple-HKP: 3`. |
| User-Agent | `AirPlay/870.14.1` in Current FreeTube. |
| Content-Type | `application/octet-stream`. |
| KEX | X25519 ephemeral (RFC 7748). |
| Identity | Ed25519 long-term keys from pair-setup (RFC 8032). |

### Pair-verify flow

| Step | Direction | TLV body |
|---|---|---|
| M1 | Controller to receiver | `SequenceNum=0x01`, `PublicKey=controller_x25519_public` (32 bytes) |
| M2 | Receiver to controller | `SequenceNum=0x02`, `PublicKey=receiver_x25519_public` (32 bytes), `EncryptedData` |
| M3 | Controller to receiver | `SequenceNum=0x03`, `EncryptedData` |
| M4 | Receiver to controller | `SequenceNum=0x04` |

### M2 encrypted data

| Item | Value |
|---|---|
| Shared secret | `X25519(controller_ephemeral_private, receiver_ephemeral_public)` (RFC 7748); 32 bytes. |
| HKDF salt | `Pair-Verify-Encrypt-Salt` |
| HKDF info | `Pair-Verify-Encrypt-Info` |
| HKDF output | 32-byte ChaCha20-Poly1305 (RFC 8439) key; HKDF-SHA512 per RFC 5869. |
| Nonce | 12 bytes: four zero bytes, then ASCII `PV-Msg02`. |
| AAD | empty |
| Plaintext TLV | `Identifier=device_id`, `Signature=receiver_signature` |
| Signature material | `receiver_x25519_public || device_id || controller_x25519_public` |
| Verification key | receiver Ed25519 LTPK from pair-setup. |

### M3 encrypted data

| Item | Value |
|---|---|
| Nonce | 12 bytes: four zero bytes, then ASCII `PV-Msg03`. |
| AAD | empty |
| Plaintext TLV | `Identifier=controller_pairing_id`, `Signature=controller_signature` |
| Signature material | `controller_x25519_public || controller_pairing_id || receiver_x25519_public` |
| Signing key | controller Ed25519 LTSK from pair-setup. |

### M4 handoff

| Rule | Value |
|---|---|
| Success marker | TLV `SequenceNum=0x04`. |
| Excess bytes | Any bytes read after the M4 HTTP body are preserved as already-encrypted HAP frames. |
| Transport keys | Derived from the pair-verify X25519 shared secret. |

## 5. HAP encrypted transport

### Control-channel HKDF labels

| Direction from controller perspective | Salt | Info | Size |
|---|---|---|---:|
| Encrypt/write | `Control-Salt` | `Control-Write-Encryption-Key` | 32 bytes |
| Decrypt/read | `Control-Salt` | `Control-Read-Encryption-Key` | 32 bytes |

### HAP frame layout

| Offset | Size | Field | Encoding |
|---:|---:|---|---|
| 0 | 2 | Plaintext length | Little-endian unsigned 16-bit. Also AEAD AAD. |
| 2 | N | Ciphertext | ChaCha20-Poly1305 encrypted payload. |
| 2+N | 16 | Authentication tag | Poly1305 tag. |

| Property | Value |
|---|---|
| AEAD | ChaCha20-Poly1305, RFC 8439. |
| Nonce | 12 bytes: four zero bytes, then 64-bit little-endian frame counter. |
| Counter start | `0`. |
| Counter scope | Separate send and receive counters per TCP connection. |
| AAD | The 2-byte little-endian length prefix. |
| Current FreeTube outgoing chunk | 1024 plaintext bytes maximum per HAP frame. |
| Current FreeTube incoming cap | 65536 plaintext bytes per HAP frame. |
| Message reassembly | Multiple HAP frames may carry one RTSP/HTTP message; HTTP/RTSP `Content-Length` determines completion. |

## 6. Two-connection architecture

| Connection | TCP target | Authentication | Primary purpose |
|---|---|---|---|
| Connection 1 | AirPlay SRV port | HAP pair-verify | Remote-control session, MRP setup, MRP event channel. |
| Connection 2 | AirPlay SRV port | HAP pair-verify | URL playback, NTP timing, media event channel, feedback. |
| Event channel 1 | `eventPort` from Connection 1 SETUP | HAP encrypted; see section 8 | Asynchronous RTSP events for remote-control session. |
| Event channel 2 | `eventPort` from Connection 2 SETUP | HAP encrypted; see section 8 | Asynchronous RTSP events for media session. |
| MRP DataStream | `dataPort` from Connection 1 stream SETUP | HAP encrypted with DataStream keys | Media Remote Protocol protobuf frames. |
| HLS HTTP | FreeTube HTTP server | normal HTTP | Apple TV fetches HLS playlists and media segments. |

### Per-connection identifiers

| Identifier | Scope | Format in Current FreeTube |
|---|---|---|
| `sessionUUID` | per RTSP connection | uppercase UUID string |
| RTSP URI session id | per RTSP connection | random unsigned 32-bit decimal in URI path |
| `CSeq` | per RTSP/HTTP connection | starts at `0`; increments by one per request |
| `DACP-ID` | per RTSP connection | random 64-bit uppercase hex string |
| `Active-Remote` | per RTSP connection | random 32-bit decimal string |
| `Client-Instance` | per RTSP connection | same value as `DACP-ID` |
| stream id | Connection 2 stream | receiver-assigned `streams[0].streamID` |

### Connection 1 order

| Order | Operation | Body class |
|---:|---|---|
| 1 | TCP connect to SRV port | none |
| 2 | HAP pair-verify M1-M4 | TLV8 |
| 3 | HAP control encryption starts | HAP frames |
| 4 | RTSP `SETUP` | remote-control binary plist |
| 5 | TCP connect to `eventPort` | event channel |
| 6 | RTSP `RECORD` | none |
| 7 | RTSP `SETUP` streams | MRP DataStream binary plist |
| 8 | TCP connect to `dataPort` | MRP DataStream |

### Connection 2 order

| Order | Operation | Body class |
|---:|---|---|
| 1 | TCP connect to SRV port | none |
| 2 | HAP pair-verify M1-M4 | TLV8 |
| 3 | HAP control encryption starts | HAP frames |
| 4 | RTSP `SETUP` | NTP binary plist |
| 5 | TCP connect to `eventPort` | event channel |
| 6 | RTSP `RECORD` | none |
| 7 | RTSP `SETUP` streams | URL-playback binary plist |
| 8 | HTTP `POST /command` | `insertPlayQueueItem` binary plist |
| 9 | HTTP `POST /command` | `setProperty` / `setRate` binary plists |
| 10 | RTSP `POST /rate?value=1.000000` | none |
| 11 | periodic RTSP `POST /feedback` | none |

## 7. RTSP over HAP

| Property | Value |
|---|---|
| Transport | HAP-encrypted TCP plaintext payload. |
| Protocol line | RTSP/1.0. |
| Header separator | CRLF. |
| Body separator | empty CRLF line. |
| Body encoding | Binary plist unless otherwise stated. |

### RTSP request grammar

| Component | Shape |
|---|---|
| Request line | `METHOD SP URI SP RTSP/1.0 CRLF` |
| Header line | `field-name ':' optional-space field-value CRLF` |
| End of headers | `CRLF` |
| Body | exactly `Content-Length` bytes when `Content-Length` is present |

### Required RTSP headers

| Header | Value |
|---|---|
| `User-Agent` | `AirPlay/550.10` in Current FreeTube |
| `CSeq` | per-connection incrementing integer |
| `DACP-ID` | per-connection random uppercase hex |
| `Active-Remote` | per-connection random decimal |
| `Client-Instance` | same as `DACP-ID` |
| `Content-Type` | `application/x-apple-binary-plist` when body present |
| `Content-Length` | body byte length when body present |

### URI forms

| Case | URI shape |
|---|---|
| Connection request with no explicit path | `rtsp://<local-ip>/<rtsp-session-id>` |
| IPv6 local address | `rtsp://[<local-ipv6>]/<rtsp-session-id>` |
| RTSP control path | path only, for example `/rate?value=1.000000` |

### RTSP methods used

| Method | Path / URI | Body | Purpose |
|---|---|---|---|
| `SETUP` | RTSP session URI | binary plist | Establish remote-control or NTP session. |
| `RECORD` | RTSP session URI | none | Begin session after `SETUP`. |
| `SETUP` | RTSP session URI | binary plist with `streams` | Open MRP or URL-playback stream. |
| `GET_PARAMETER` | event channel request from receiver | optional | Must be acknowledged on event channel. |
| `SET_PARAMETER` | event channel request from receiver | optional | Must be acknowledged on event channel. |
| `POST` | `/feedback` | none | Keepalive during playback. |
| `POST` | `/rate?value=<float>` | none | RTSP-level play trigger in Current FreeTube. |
| `POST` | `/scrub?position=<seconds>` | none | Seek. |
| `GET` | `/playback-info` | none | Query playback state. |
| `TEARDOWN` | RTSP session URI | none | Stop playback session. |

### Connection 1 SETUP body

| Binary plist key | Type | Value in Current FreeTube |
|---|---|---|
| `isRemoteControlOnly` | bool | true |
| `timingProtocol` | string | `None` |
| `deviceID` | string | `FF:70:79:61:74:76` |
| `macAddress` | string | `02:70:79:61:74:76` |
| `sessionUUID` | string | connection UUID |
| `model` | string | `iPhone10,6` |
| `name` | string | `FreeTube` |
| `osBuildVersion` | string | `18G82` |
| `osName` | string | `iPhone OS` |
| `osVersion` | string | `14.7.1` |
| `sourceVersion` | string | `550.10` |

| Response key | Type | Meaning |
|---|---|---|
| `eventPort` | unsigned integer | TCP port for Connection 1 event channel. |

### Connection 2 SETUP body

| Binary plist key | Type | Value in Current FreeTube |
|---|---|---|
| `deviceID` | string | `AA:BB:CC:DD:EE:FF` |
| `sessionUUID` | string | connection UUID |
| `timingPort` | integer | local UDP NTP timing port |
| `timingProtocol` | string | `NTP` |
| `isMultiSelectAirPlay` | bool | true |
| `groupContainsGroupLeader` | bool | false |
| `macAddress` | string | `AA:BB:CC:DD:EE:FF` |
| `model` | string | `iPhone14,3` |
| `name` | string | `FreeTube` |
| `osBuildVersion` | string | `20F66` |
| `osName` | string | `iPhone OS` |
| `osVersion` | string | `16.5` |
| `senderSupportsRelay` | bool | false |
| `sourceVersion` | string | `690.7.1` |
| `statsCollectionEnabled` | bool | false |

Empirically observed (FreeTube): `sessionCorrelationUUID` is omitted for pyatv 0.17-compatible behavior.

### MRP stream SETUP body

| Binary plist path | Type | Value |
|---|---|---|
| `streams[0].channelID` | string | uppercase UUID |
| `streams[0].clientTypeUUID` | string | `1910A70F-DBC0-4242-AF95-115DB30604E1` |
| `streams[0].clientUUID` | string | uppercase UUID |
| `streams[0].controlType` | integer | `2` |
| `streams[0].seed` | integer | random 64-bit value; generated little-endian from random bytes in Current FreeTube |
| `streams[0].type` | integer | `130` |
| `streams[0].wantsDedicatedSocket` | bool | true |

| Response path | Type | Meaning |
|---|---|---|
| `streams[0].dataPort` | unsigned integer | TCP port for MRP DataStream channel. |

### URL-playback stream SETUP body

| Binary plist path | Type | Value in Current FreeTube |
|---|---|---|
| `streams[0].channelID` | string | `36:CB:3F:E1:93:B0-RCS-1` |
| `streams[0].clientTypeUUID` | string | `A6B27562-B43A-4F2D-B75F-82391E250194` |
| `streams[0].clientUUID` | string | `2E0A9FBA-182D-4E04-8A5D-EC018BD8C408` |
| `streams[0].controlType` | integer | `1` |
| `streams[0].type` | integer | `130` |

| Response path | Type | Meaning |
|---|---|---|
| `streams[0].streamID` | unsigned integer | Required in `X-Apple-StreamID` on playback commands. |

## 8. Event channels

| Property | Value |
|---|---|
| TCP target | Apple TV address and `eventPort` from the parent connection's SETUP response. |
| TCP option | `TCP_NODELAY` in Current FreeTube. |
| Payloads | HAP frames carrying RTSP requests/responses and binary plists. |
| Liveness | Non-fatal in Current FreeTube; failure is logged and playback proceeds. |
| Read timeout | 300 seconds in event reader tasks. |

### Event channel authentication and keys

| Mode | Status | Key source | HKDF labels |
|---|---|---|---|
| Parent-secret HKDF | Current FreeTube; Empirically observed (FreeTube) accepted by tvOS 26.x | Parent RTSP connection X25519 shared secret | `Events-Salt`, `Events-Read-Encryption-Key`, `Events-Write-Encryption-Key` |
| Separate event pair-verify | Present as inactive compatibility path in Current FreeTube | Event-channel X25519 shared secret | same Events labels |

Empirically observed (FreeTube): event-channel `Read` and `Write` labels are from the Apple TV perspective. Controller encrypts with `Events-Read-Encryption-Key` and decrypts with `Events-Write-Encryption-Key`.

### Event channel RTSP acknowledgement

| Incoming receiver request starts with | Required controller response |
|---|---|
| `POST`, `GET`, `SET_PARAMETER`, `GET_PARAMETER`, `OPTIONS`, `ANNOUNCE`, `RECORD`, `SETUP`, `TEARDOWN` | RTSP `200 OK` with matching `CSeq` and `Content-Length: 0`. |

Empirically observed (FreeTube): failing to acknowledge receiver RTSP requests on the event channel can close all AirPlay connections and stop playback.

## 9. MRP DataStream channel

| Property | Value |
|---|---|
| Establishment | Connection 1 `SETUP` streams with `controlType=2`, then TCP to returned `dataPort`. |
| Encryption | HAP framing with DataStream HKDF keys. |
| Payload class | 32-byte DataStream header plus optional binary plist payload. |
| Protobuf wrapper | length-delimited protobuf bytes inside `params.data` binary plist. |

### DataStream HKDF labels

| Direction from controller perspective | Salt | Info | Size |
|---|---|---|---:|
| Encrypt/write | `DataStream-Salt<seed-decimal>` | `DataStream-Output-Encryption-Key` | 32 bytes |
| Decrypt/read | `DataStream-Salt<seed-decimal>` | `DataStream-Input-Encryption-Key` | 32 bytes |

### DataStream header layout

| Offset | Size | Field | Encoding / value |
|---:|---:|---|---|
| 0 | 4 | Total size | Big-endian unsigned 32-bit; includes 32-byte header. |
| 4 | 12 | Message type tag | `sync` plus eight zero bytes, or `rply` plus eight zero bytes. |
| 16 | 4 | Command field | `comm` for `sync`; four zero bytes for `rply`. |
| 20 | 8 | Sequence number | Big-endian unsigned 64-bit. |
| 28 | 4 | Padding | four zero bytes. |
| 32 | N | Payload | binary plist for `sync`; absent for `rply`. |

### DataStream sequence numbers

| Item | Value |
|---|---|
| Initial controller sequence | `0x100000000 | random_u32`. |
| Increment | +1 per sent `sync` frame. |
| Receiver `sync` handling | Reply with `rply` using identical sequence number. |
| `rply` size | 32 bytes. |

### `sync` payload

| Binary plist path | Type | Meaning |
|---|---|---|
| `params.data` | bytes | protobuf varint length prefix followed by protobuf message bytes. |

### Protobuf envelope fields used

| Field number | Name | Type / values used |
|---:|---|---|
| 1 | message type | enum: 15, 16, 24, 38 |
| 2 | identifier | string UUID on selected messages |
| 4 | error code | integer, `0` in Current FreeTube sent messages |
| 20 | device info message | nested message |
| 21 | client updates config message | nested message |
| 29 | get keyboard session message | empty / absent body; type tag carries meaning |
| 42 | set connection state message | nested message |
| 85 | unique identifier | string UUID |

### Message type values

| Value | Name | Current FreeTube order |
|---:|---|---:|
| 15 | Device info | 1 |
| 38 | Set connection state | 2 |
| 16 | Client updates config | 3 |
| 24 | Get keyboard session | 4 |

### Device info values sent

| Field | Value in Current FreeTube |
|---|---|
| name | `FreeTube` |
| localized model name | `iPhone` |
| system build version | `18G82` |
| application bundle identifier | `com.apple.TVRemote` |
| application bundle version | `344.28` |
| protocol version | `1` |
| last supported message type | `108` |
| supports system pairing | true |
| allows pairing | true |
| system media application | `com.apple.TVMusic` |
| supports ACL | true |
| supports shared queue | true |
| supports extended motion | true |
| shared queue version | `2` |
| device class | iPhone, enum value `1` |
| logical device count | `1` |

### Other initial MRP values sent

| Message | Field | Value |
|---|---|---|
| Set connection state | state | connected, enum value `2` |
| Client updates config | artwork updates | true |
| Client updates config | now playing updates | false |
| Client updates config | volume updates | true |
| Client updates config | keyboard updates | true |
| Client updates config | output device updates | true |
| Get keyboard session | body | empty; message type only |

## 10. Playback commands on URL/media connection

| Property | Value |
|---|---|
| Transport | HAP-encrypted Connection 2. |
| HTTP path | `/command`. |
| HTTP protocol | HTTP/1.1. |
| User-Agent | `AirPlay/870.14.1` in Current FreeTube. |
| Content-Type | `application/x-apple-binary-plist`. |
| Required headers | `X-Apple-ProtocolVersion: 1`, `X-Apple-Session-ID`, `X-Apple-StreamID`, `CSeq`, `Content-Length`. |
| Body envelope | outer binary plist dictionary, `params.data` contains inner binary plist bytes. |

### `insertPlayQueueItem` inner plist

| Key path | Type | Current FreeTube value |
|---|---|---|
| `type` | string | `insertPlayQueueItem` |
| `item.uuid` | string | uppercase item UUID |
| `item.mediaType` | string | `file` |
| `item.Content-Location` | string | HLS master playlist URL |

### `insertPlayQueueItem` optional/native fields

| Key | Type | Status |
|---|---|---|
| `sourceMetadata` | dictionary | Not emitted by Current FreeTube. Optional in native/pyatv-style command traces. |
| `requestID` | string or integer | Not emitted by Current FreeTube. Optional idempotency/correlation value in native traces. |
| idempotency key fields | string UUID | Not emitted by Current FreeTube. Name varies by trace; not treated as mandatory by FreeTube's observed Apple TV target. |

Empirically observed (FreeTube): tvOS 26.x accepts the minimal four-field `insertPlayQueueItem` item body above when followed by the property and rate commands below.

### `setProperty` commands

| Property | Scope | Value type | Current FreeTube |
|---|---|---|---|
| `isInterestedInDateRange` | item UUID | bool | sent with `true` |
| `actionAtItemEnd` | command/global | integer | sent with `1` |
| `forwardEndTime` | item or command | real seconds | documented protocol field; not emitted by Current FreeTube |

### `setRate` command

| Key | Type | Pause | Resume/play |
|---|---|---:|---:|
| `type` | string | `setRate` | `setRate` |
| `rate` | real | `0.0` | `1.0` |

### Other playback controls

| Control | Wire operation | Notes |
|---|---|---|
| Pause | `/command` `setRate` with `rate=0.0` | Current FreeTube. |
| Resume | `/command` `setRate` with `rate=1.0` | Current FreeTube. |
| Stop | RTSP `TEARDOWN` on Connection 2 | Stops feedback first in Current FreeTube. |
| Scrub | RTSP `POST /scrub?position=<seconds>` | Position formatted with millisecond precision in Current FreeTube. |
| Playback info | RTSP `GET /playback-info` | Response parsed as XML plist keys `duration`, `position`, `rate`, `readyToPlay`. |
| Property query | `/command` `getProperty` | Protocol command; not emitted by Current FreeTube. |
| RTSP rate trigger | RTSP `POST /rate?value=1.000000` | Empirically observed (FreeTube): sent after command-level `setRate`; non-200 is logged as non-fatal. |
| Feedback | RTSP `POST /feedback` every 2 seconds | Empirically observed (FreeTube): needed to keep playback alive. |

### Legacy URL playback path

| Item | Value |
|---|---|
| HTTP request | `POST /play HTTP/1.1` with binary plist body `{Content-Location, Start-Position, X-Apple-Session-ID}`, `User-Agent: MediaControl/1.0`. |
| Status in FreeTube | Not used — Apple TV receivers reject this with 404. FreeTube uses the AirPlay 2 two-connection flow above. |

## 11. NTP timing channel

| Property | Value |
|---|---|
| Controller bind address | UDP `0.0.0.0:0` in Current FreeTube. |
| Advertised parameter | Connection 2 SETUP `timingProtocol = NTP`. |
| Advertised port | Connection 2 SETUP `timingPort = <local UDP port>`. |
| Packet size used | 32 bytes. |
| Timestamp epoch | NTP epoch, 1900-01-01 00:00:00 UTC, RFC 5905. |
| Unix-to-NTP seconds offset | `2208988800`. |

### Timing response packet layout

| Offset | Size | Field | Encoding / value |
|---:|---:|---|---|
| 0 | 1 | Protocol | copied from request byte 0. |
| 1 | 1 | Type | `0xd3`, computed as `0x53 | 0x80`. |
| 2 | 2 | Sequence number | big-endian `7`. |
| 4 | 4 | Padding | zero. |
| 8 | 4 | Origin timestamp seconds | request bytes 24..27. |
| 12 | 4 | Origin timestamp fraction | request bytes 28..31. |
| 16 | 4 | Receive timestamp seconds | current NTP seconds, big-endian. |
| 20 | 4 | Receive timestamp fraction | current NTP fraction, big-endian. |
| 24 | 4 | Send timestamp seconds | current NTP seconds, big-endian. |
| 28 | 4 | Send timestamp fraction | current NTP fraction, big-endian. |

| Fraction formula | Value |
|---|---|
| NTP fractional seconds | `(nanoseconds << 32) / 1000000000` |

Empirically observed (FreeTube): tvOS 26.x (Apple TV 4K gen 3) requires the controller to actively answer NTP timing probes before Connection 2 SETUP completes; without a responder the SETUP request returns HTTP 400 after a ~30 s receiver-side timeout. Earlier Apple TV models accept SETUP without an active responder. Current FreeTube therefore always runs a real NTP timing responder on the advertised `timingPort` (`Ntp_timing.start`, fixed port `7011`).

## 12. Binary plist usage

| Item | Value |
|---|---|
| Magic | `bplist00` at bytes 0..7. |
| Content-Type | `application/x-apple-binary-plist`. |
| Top-level container | dictionary in FreeTube AirPlay requests. |
| Nested commands | `/command` outer plist contains inner plist bytes at `params.data`. |
| Recursive logging helper | Current FreeTube unwraps nested `Data` values whose bytes start with `bplist00`. |

| Context | Body format |
|---|---|
| RTSP `SETUP` | binary plist dictionary. |
| RTSP stream `SETUP` | binary plist dictionary with `streams` array. |
| HTTP `POST /command` | binary plist dictionary containing nested binary plist command. |
| Event channel receiver messages | RTSP payloads; body often binary plist. |
| MRP `sync` payload | binary plist dictionary containing length-delimited protobuf bytes. |

## 13. HLS constraints for Apple TV

| Constraint | Status | Detail |
|---|---|---|
| Container format | Empirically observed (FreeTube) | Apple TV boxes (tvOS) require HLS for AirPlay 2 URL playback. Plain progressive `video/mp4` URLs play audio only; HLS (master + per-track media playlists, fMP4 segments) plays both video and audio. |
| `FRAME-RATE` on every `EXT-X-STREAM-INF` | Empirically observed (FreeTube) | Omission causes Apple TV playback failure/silent skip for FreeTube-generated HLS, including streams otherwise natively decodable. |
| HLS master codec strings | Spec plus Empirically observed (FreeTube) | Use RFC 6381-style strings accepted by Apple TV. |
| Audio codec for AirPlay route | Empirically observed (FreeTube) | AAC is selected ahead of Opus; HLS fMP4 Opus is not accepted by this AirPlay path. |
| Default Apple TV prefs | Current FreeTube | video `[hev1, avc1]`, audio `[aac]`, dynamic range `[sdr]`, transcode disabled. |

### Codec strings used/accepted in this path

| Family | Codec string examples |
|---|---|
| H.264 | `avc1.*`, for example `avc1.640028` |
| HEVC | `hvc1.*` or `hev1.*`; FreeTube normalizes family as `hev1` internally |
| AAC-LC | `mp4a.40.2` |

Empirically observed (FreeTube): Apple TV can decode HEVC HDR10/Dolby Vision natively when the HLS manifest is well-formed for the device, but FreeTube seeds SDR-only Apple TV preferences conservatively.

## 14. tvOS 26.x error and timeout behavior

| Observation | Status | Detail |
|---|---|---|
| pyatv 0.17.0 `play_url()` failure on tvOS 26.2 | Empirically observed (FreeTube) and upstream pyatv report | Upstream issue: [postlund/pyatv#2821](https://github.com/postlund/pyatv/issues/2821). |
| pyatv context / follow-up | Upstream pyatv | Related PR: [postlund/pyatv#2846](https://github.com/postlund/pyatv/pull/2846). |
| Reported symptom | Upstream pyatv issue | `GET /playback-info` returns HTTP 500 after `play_url()` on Apple TV 4K tvOS 26.2. |
| FreeTube mitigation direction | Empirically observed (FreeTube) | Use AirPlay 2 two-connection flow, MRP data channel, `/command` `insertPlayQueueItem`, event-channel ACKs, and feedback keepalive instead of relying only on legacy `POST /play`. |
| Pairing timing | Empirically observed (FreeTube) | `/pair-setup` M1 must follow `/pair-pin-start` promptly; delayed M1 can be rejected with HTTP 470. |
| Event-channel ACK timeout | Empirically observed (FreeTube) | Missing RTSP `200 OK` ACKs can cause receiver-side connection teardown. |
| HAP receive timeout | Current FreeTube | 10 seconds waiting for complete RTSP/HTTP response on control connections. |
| Event read timeout | Current FreeTube | 300 seconds; timeout is treated as idle and reader continues. |

## 15. User-agent strings

| Context | User-Agent |
|---|---|
| Pair PIN start | `MediaControl/1.0` |
| Pair setup | `AirPlay/320.20` |
| Pair verify and HTTP `/command` | `AirPlay/870.14.1` |
| RTSP over HAP | `AirPlay/550.10` |

Empirically observed (FreeTube): different phases use different AirPlay-era user-agent strings; the values above are encoded in `src/airplay/pairing.rs` and `src/airplay/session.rs`.

## 16. Session teardown and cleanup

| Event | Wire behavior |
|---|---|
| New playback request while one is active | Current FreeTube sends Connection 2 `TEARDOWN`, removes prior server-side HLS session, then starts a new AirPlay session. |
| Explicit stop | Abort feedback task, send Connection 2 `TEARDOWN`, drop Connection 2. |
| Session drop | Abort event-channel and feedback tasks. |
| Event/MRP background failure | Logged; generally non-fatal to initial session setup. |
