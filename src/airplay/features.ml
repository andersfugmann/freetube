open! Base

type t =
  | Supports_airplay_video_v1
  | Supports_airplay_photo
  | Supports_airplay_slideshow
  | Supports_airplay_screen
  | Supports_airplay_audio
  | Audio_redundant
  | Authentication_4
  | Metadata_features_0
  | Metadata_features_1
  | Metadata_features_2
  | Audio_formats_0
  | Audio_formats_1
  | Audio_formats_2
  | Audio_formats_3
  | Authentication_1
  | Authentication_8
  | Supports_legacy_pairing
  | Has_unified_advertiser_info
  | Is_carplay
  | Supports_airplay_video_play_queue
  | Supports_airplay_from_cloud
  | Supports_tls_psk
  | Supports_unified_media_control
  | Supports_buffered_audio
  | Supports_ptp
  | Supports_screen_multi_codec
  | Supports_system_pairing
  | Is_ap_valeria_screen_sender
  | Supports_hk_pairing_and_access_control
  | Supports_core_utils_pairing_and_encryption
  | Supports_airplay_video_v2
  | Metadata_features_3
  | Supports_unified_pair_setup_and_mfi
  | Supports_set_peers_extended_message
  | Supports_ap_sync
  | Supports_wol
  | Supports_wol2
  | Supports_hangdog_remote_control
  | Supports_audio_stream_connection_setup
  | Supports_audio_metadata_control
  | Supports_rfc2198_redundancy
[@@deriving yojson]

let bits = [
  0,  Supports_airplay_video_v1;
  1,  Supports_airplay_photo;
  5,  Supports_airplay_slideshow;
  7,  Supports_airplay_screen;
  9,  Supports_airplay_audio;
  11, Audio_redundant;
  14, Authentication_4;
  15, Metadata_features_0;
  16, Metadata_features_1;
  17, Metadata_features_2;
  18, Audio_formats_0;
  19, Audio_formats_1;
  20, Audio_formats_2;
  21, Audio_formats_3;
  23, Authentication_1;
  26, Authentication_8;
  27, Supports_legacy_pairing;
  30, Has_unified_advertiser_info;
  32, Is_carplay;
  33, Supports_airplay_video_play_queue;
  34, Supports_airplay_from_cloud;
  35, Supports_tls_psk;
  38, Supports_unified_media_control;
  40, Supports_buffered_audio;
  41, Supports_ptp;
  42, Supports_screen_multi_codec;
  43, Supports_system_pairing;
  44, Is_ap_valeria_screen_sender;
  46, Supports_hk_pairing_and_access_control;
  48, Supports_core_utils_pairing_and_encryption;
  49, Supports_airplay_video_v2;
  50, Metadata_features_3;
  51, Supports_unified_pair_setup_and_mfi;
  52, Supports_set_peers_extended_message;
  54, Supports_ap_sync;
  55, Supports_wol;
  56, Supports_wol2;
  58, Supports_hangdog_remote_control;
  59, Supports_audio_stream_connection_setup;
  60, Supports_audio_metadata_control;
  61, Supports_rfc2198_redundancy;
]

let parse_hex32 s =
  let stripped =
    match String.chop_prefix s ~prefix:"0x" with
    | Some rest -> rest
    | None -> s
  in
  Int64.of_string ("0x" ^ stripped)

let parse s =
  match String.split (String.strip s) ~on:',' |> List.map ~f:String.strip with
  | [ lo ] -> parse_hex32 lo
  | [ lo; hi ] ->
      let lo = parse_hex32 lo in
      let hi = parse_hex32 hi in
      Int64.bit_or (Int64.shift_left hi 32) lo
  | _ -> Printf.failwithf "invalid feature string: %s" s ()

let decode s =
  let value =
    match Result.try_with (fun () -> parse s) with
    | Ok v -> v
    | Error _ -> 0L
  in
  List.filter_map bits ~f:(fun (bit, name) ->
    let mask = Int64.shift_left 1L bit in
    match Int64.(equal (bit_and value mask) zero) with
    | true -> None
    | false -> Some name)

