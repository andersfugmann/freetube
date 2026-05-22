open! Base
open Util

type t = Api.Vendor.t = Apple | Samsung | Lg | Generic
[@@deriving yojson, equal]

let to_string = Api.Vendor.to_string
let default_video_codecs = Api.Vendor.default_video_codecs
let default_audio_codecs = Api.Vendor.default_audio_codecs

module Log = (val Log_src.src_log ~doc:"Device vendor derivation for HLS profile gating" Stdlib.__MODULE__)

let lc_contains haystack needle =
  String.is_substring (String.lowercase haystack) ~substring:needle

let of_manufacturer manufacturer =
  match () with
  | _ when lc_contains manufacturer "samsung" -> Some Samsung
  | _ when lc_contains manufacturer "lg"      -> Some Lg
  | _ when lc_contains manufacturer "apple"   -> Some Apple
  | _ -> None

let apple_model_prefixes =
  [ "AppleTV"; "iPhone"; "iPad"; "iPod"; "Mac"; "HomePod"
  ; "AudioAccessory"; "iProd"; "RealityDevice"; "Watch" ]

let of_apple_model model =
  List.exists apple_model_prefixes ~f:(fun p -> String.is_prefix model ~prefix:p)

let log_choice ~friendly_name ~manufacturer ~model vendor =
  let m_str = Option.value manufacturer ~default:"<none>" in
  let mo_str = Option.value model ~default:"<none>" in
  Log.info (fun m ->
    m "%s: manufacturer=%S model=%S -> %s"
      friendly_name m_str mo_str (to_string vendor))

let of_airplay ~txt ~model =
  let manufacturer =
    List.Assoc.find txt ~equal:String.equal "manufacturer"
  in
  let vendor =
    match manufacturer with
    | Some m ->
        (match of_manufacturer m with
         | Some v -> v
         | None -> Generic)
    | None ->
        (match model with
         | Some m when of_apple_model m -> Apple
         | _ -> Generic)
  in
  manufacturer, vendor

let of_dlna ~manufacturer =
  match of_manufacturer manufacturer with
  | Some v -> v
  | None -> Generic

let log_airplay ~friendly_name ~manufacturer ~model vendor =
  log_choice ~friendly_name ~manufacturer ~model vendor

let log_dlna ~friendly_name ~manufacturer ~model_name vendor =
  log_choice ~friendly_name
    ~manufacturer:(Some manufacturer)
    ~model:(Some model_name) vendor

let%expect_test "of_manufacturer matches case-insensitively" =
  List.iter [ "LG"; "lg"; "LG Electronics"; "Samsung"; "samsung"; "Apple Inc.";
              "Yamaha Corporation"; "" ] ~f:(fun m ->
    let v =
      match of_manufacturer m with
      | Some v -> to_string v
      | None -> "Generic"
    in
    Stdlib.Printf.printf "%S -> %s\n" m v);
  [%expect {|
    "LG" -> Lg
    "lg" -> Lg
    "LG Electronics" -> Lg
    "Samsung" -> Samsung
    "samsung" -> Samsung
    "Apple Inc." -> Apple
    "Yamaha Corporation" -> Generic
    "" -> Generic
    |}]

let%expect_test "of_apple_model matches Apple model strings" =
  List.iter [ "AppleTV14,1"; "iPhone15,3"; "HomePod1,1"; "AudioAccessory6,1";
              "Watch7,1"; "OLED48C44LA.DEUQLJP"; "RX-V6A" ] ~f:(fun m ->
    Stdlib.Printf.printf "%s -> %b\n" m (of_apple_model m));
  [%expect {|
    AppleTV14,1 -> true
    iPhone15,3 -> true
    HomePod1,1 -> true
    AudioAccessory6,1 -> true
    Watch7,1 -> true
    OLED48C44LA.DEUQLJP -> false
    RX-V6A -> false
    |}]
