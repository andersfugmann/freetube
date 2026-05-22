open! Base

(* Codec ADTs are derived with ppx_deriving_yojson. By default this produces
   `List [`String "Constructor"]` envelopes; we strip/add the [`List] wrapper
   so that JSON values, [to_string], and [of_string] all share the same
   canonical [`String name] representation. *)

let strip_envelope = function
  | `List [ inner ] -> inner
  | json ->
      failwith
        (Printf.sprintf
           "codec: unexpected yojson envelope: %s"
           (Yojson.Safe.to_string json))

let add_envelope inner = `List [ inner ]

let bare_to_yojson to_yojson t = strip_envelope (to_yojson t)
let bare_of_yojson of_yojson j = of_yojson (add_envelope j)

let bare_to_string to_yojson t =
  match bare_to_yojson to_yojson t with
  | `String s -> s
  | json ->
      failwith
        (Printf.sprintf "codec: expected String, got: %s" (Yojson.Safe.to_string json))

let bare_of_string of_yojson ~unknown s =
  match bare_of_yojson of_yojson (`String s) with
  | Ok v -> v
  | Error _ -> unknown

module Video = struct
  type t =
    | Av1 [@name "av1"]
    | Hevc [@name "hevc"]
    | Vp9 [@name "vp9"]
    | Avc [@name "avc"]
    | Unknown [@name "unknown"]
  [@@deriving yojson, compare, equal, show{ with_path = false }]

  let to_string = bare_to_string to_yojson
  let of_string = bare_of_string of_yojson ~unknown:Unknown

  (* yt-dlp emits full RFC 6381 codec strings such as ["avc1.640028"],
     ["vp09.00.51.08"], or ["av01.0.08M.08"]. Map the prefix to our ADT. *)
  let of_rfc6381 s =
    match String.split s ~on:'.' with
    | "avc1" :: _ -> Avc
    | ("hev1" | "hvc1") :: _ -> Hevc
    | ("vp09" | "vp9") :: _ -> Vp9
    | "av01" :: _ -> Av1
    | _ -> Unknown

  let parse_avc s =
    match String.split s ~on:'.' with
    | "avc1" :: hex :: _ | ("hev1" | "hvc1") :: hex :: _ ->
        (match Int.of_string_opt ("0x" ^ hex) with
         | Some n when String.length hex >= 4 ->
             let profile_idc = n lsr 16 in
             let level_idc = n land 0xFF in
             profile_idc, level_idc
         | _ -> 0, 0)
    | _ -> 0, 0

  let parse_hevc = parse_avc

  let parse_vp9 s =
    match String.split s ~on:'.' with
    | ("vp09" | "vp9") :: p :: _ -> Option.value (Int.of_string_opt p) ~default:0
    | _ -> 0

  let parse_av1 s =
    match String.split s ~on:'.' with
    | "av01" :: p :: _ :: bd :: _ ->
        Option.value (Int.of_string_opt p) ~default:0,
        Option.value (Int.of_string_opt bd) ~default:8
    | _ -> 0, 8
end

module Audio = struct
  type t =
    | Opus [@name "opus"]
    | Aac [@name "aac"]
    | Flac [@name "flac"]
    | Vorbis [@name "vorbis"]
    | Unknown [@name "unknown"]
  [@@deriving yojson, compare, equal, show { with_path = false }]

  let to_string = bare_to_string to_yojson
  let of_string = bare_of_string of_yojson ~unknown:Unknown

  let of_rfc6381 s =
    match String.split s ~on:'.' with
    | "mp4a" :: _ -> Aac
    | [ "opus" ] -> Opus
    | [ "vorbis" ] -> Vorbis
    | [ "flac" ] -> Flac
    | _ -> Unknown

  type aac_profile = Lc | He | He_v2

  let parse_aac s =
    match String.split s ~on:'.' with
    | "mp4a" :: _ :: "2" :: _ -> Lc
    | "mp4a" :: _ :: "5" :: _ -> He
    | "mp4a" :: _ :: "29" :: _ -> He_v2
    | _ -> Lc
end

module Dynamic_range = struct
  type t =
    | Dolby_vision [@name "dv"]
    | Hdr10_plus [@name "hdr10+"]
    | Hdr10 [@name "hdr10"]
    | Hlg [@name "hlg"]
    | Sdr [@name "sdr"]
  [@@deriving yojson, compare, equal]

  let derived_of_yojson = of_yojson
  let to_yojson = bare_to_yojson to_yojson

  let of_yojson = function
    | `String s -> bare_of_yojson derived_of_yojson (`String (String.lowercase s))
    | _ -> Error "expected string for dynamic_range"

  let to_string t =
    match to_yojson t with
    | `String s -> s
    | json ->
        failwith
          (Printf.sprintf
             "dynamic_range: expected String, got: %s"
             (Yojson.Safe.to_string json))
end

(** Derive an RFC 6381 codec string for encoder output given codec type and
    stream parameters. Used to populate manifest CODECS attributes when
    transcoding. *)
module Rfc6381 = struct
  (** AVC level from resolution and frame rate (ITU-T H.264 Table A-1).
      Returns the level_idc byte. *)
  let avc_level ~width ~height ~fps =
    let macroblocks = ((width + 15) / 16) * ((height + 15) / 16) in
    let mbps = Float.to_int (Float.of_int macroblocks *. fps) in
    match () with
    | () when mbps <= 40_500  && macroblocks <= 1_620  -> 0x1F (* 3.1 *)
    | () when mbps <= 108_000 && macroblocks <= 3_600  -> 0x20 (* 3.2 *)
    | () when mbps <= 216_000 && macroblocks <= 8_192  -> 0x28 (* 4.0 *)
    | () when mbps <= 245_760 && macroblocks <= 8_192  -> 0x29 (* 4.1 *)
    | () when mbps <= 522_240 && macroblocks <= 8_704  -> 0x2A (* 4.2 *)
    | () when mbps <= 589_824 && macroblocks <= 22_080 -> 0x33 (* 5.1 *)
    | () when mbps <= 983_040 && macroblocks <= 36_864 -> 0x34 (* 5.2 *)
    | () -> 0x3C (* 6.0 *)

  (** HEVC level from resolution and frame rate (ITU-T H.265 Table A.6).
      Returns level_idc (30 * level). *)
  let hevc_level ~width ~height ~fps =
    let luma_samples = width * height in
    let luma_sr = Float.to_int (Float.of_int luma_samples *. fps) in
    match () with
    | () when luma_sr <= 33_177_600  && luma_samples <= 2_228_224  -> 120 (* 4.0 *)
    | () when luma_sr <= 66_846_720  && luma_samples <= 2_228_224  -> 123 (* 4.1 *)
    | () when luma_sr <= 133_693_440 && luma_samples <= 8_912_896  -> 150 (* 5.0 *)
    | () when luma_sr <= 267_386_880 && luma_samples <= 8_912_896  -> 153 (* 5.1 *)
    | () when luma_sr <= 534_773_760 && luma_samples <= 8_912_896  -> 156 (* 5.2 *)
    | () -> 180 (* 6.0 *)

  (** AV1 level_idx from resolution and frame rate (AV1 spec §A.3). *)
  let av1_level ~width ~height ~fps =
    let pixels = width * height in
    let display_rate = Float.to_int (Float.of_int pixels *. fps) in
    match () with
    | () when display_rate <= 33_177_600  && pixels <= 2_228_224  -> 8  (* 4.0 *)
    | () when display_rate <= 66_846_720  && pixels <= 2_228_224  -> 9  (* 4.1 *)
    | () when display_rate <= 133_693_440 && pixels <= 8_912_896  -> 12 (* 5.0 *)
    | () when display_rate <= 267_386_880 && pixels <= 8_912_896  -> 13 (* 5.1 *)
    | () when display_rate <= 534_773_760 && pixels <= 8_912_896  -> 14 (* 5.2 *)
    | () -> 16 (* 6.0 *)

  let video ~codec ~width ~height ~fps =
    match codec with
    | Video.Avc ->
      (* VAAPI h264 always produces High profile (0x64), constraint flags 0x00 *)
      let level = avc_level ~width ~height ~fps in
      Printf.sprintf "avc1.6400%02X" level
    | Video.Hevc ->
      (* VAAPI hevc produces Main profile (1), general_tier_flag=0 (Main tier) *)
      let level = hevc_level ~width ~height ~fps in
      Printf.sprintf "hev1.1.6.L%d" level
    | Video.Av1 ->
      (* VAAPI av1 produces Main profile (0), Main tier *)
      let level_idx = av1_level ~width ~height ~fps in
      Printf.sprintf "av01.0.%02dM.08" level_idx
    | Video.Vp9 ->
      (* VP9 profile 0, level derived from resolution, 8-bit *)
      Printf.sprintf "vp09.00.10.08"
    | Video.Unknown ->
      "unknown"

  let audio = function
    | Audio.Aac -> "mp4a.40.2"
    | Audio.Opus -> "opus"
    | Audio.Vorbis -> "vorbis"
    | Audio.Flac -> "flac"
    | Audio.Unknown -> "unknown"
end
