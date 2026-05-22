open! Base

(** AirPlay 2 sender-identity fingerprint. Apple TVs only accept connections
    from devices that present a recognised model/OS combination; we
    masquerade as an iPhone 14 running iOS 16.5. Change in one place if a
    future tvOS version starts rejecting these values. *)

let device_id    = "AA:BB:CC:DD:EE:FF"
let mac_address  = "AA:BB:CC:DD:EE:FF"
let model        = "iPhone14,3"
let name         = "FreeTube"
let os_build     = "20F66"
let os_name      = "iPhone OS"
let os_version   = "16.5"
let source_version = "690.7.1"

(** Apple's stable client-type UUID for data-channel streams. *)
let data_stream_client_type_uuid = "1910A70F-DBC0-4242-AF95-115DB30604E1"

(** Apple's stable client-type UUID for URL-playback streams. *)
let url_stream_client_type_uuid  = "A6B27562-B43A-4F2D-B75F-82391E250194"

(** Opaque controller-side channel id used in URL-playback stream SETUP.
    Receivers echo this in events for multi-stream correlation; not
    validated, so any stable string works. *)
let url_stream_channel_id = "36:CB:3F:E1:93:B0-RCS-1"
