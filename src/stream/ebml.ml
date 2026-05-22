open! Base
open Util

module Log = (val Log_src.src_log ~doc:"WebM and EBML container parsing" Stdlib.__MODULE__)

type element_header = {
  id : int;
  data_size : int;
  header_size : int;
  offset : int;
}

type cue_point = {
  cue_time : int;
  cluster_offset : int;
}

type webm_index = {
  cue_points : cue_point list;
  timecode_scale : int;
  duration_ns : int option;
}

let segment_id = 0x1853_8067
let info_id = 0x1549_A966
let timecode_scale_id = 0x002A_D7B1
let duration_id = 0x4489
let cues_id = 0x1C53_BB6B
let cue_point_id = 0xBB
let cue_time_id = 0xB3
let cue_track_positions_id = 0xB7
let cue_cluster_position_id = 0xF1
let seek_head_id = 0x114D_9B74
let seek_id = 0x4DBB
let seek_id_id = 0x53AB
let seek_position_id = 0x53AC
let tracks_id = 0x1654_AE6B
let cluster_id = 0x1F43_B675

let invalid_range s ~pos ~len =
  invalid_arg
    (Stdlib.Printf.sprintf
       "container.ebml: invalid range pos=%d len=%d input=%d"
       pos len (String.length s))

let check_range s ~pos ~len =
  match pos < 0 || len < 0 || pos + len > String.length s with
  | true -> invalid_range s ~pos ~len
  | false -> ()

let get_u8 s pos = Char.to_int (String.get s pos)

let rec vint_length first_byte width mask =
  match mask = 0, first_byte land mask <> 0 with
  | true, _ -> invalid_arg "container.ebml: invalid vint"
  | false, true -> width
  | false, false -> vint_length first_byte (width + 1) (mask lsr 1)

let combine_bytes s ~pos ~len ~initial ~start_index =
  let rec loop index acc =
    match index = len with
    | true -> acc
    | false ->
        let byte = get_u8 s (pos + index) in
        loop (index + 1) ((acc lsl 8) lor byte)
  in
  loop start_index initial

let parse_vint s ~pos =
  check_range s ~pos ~len:1;
  let first_byte = get_u8 s pos in
  let bytes_consumed = vint_length first_byte 1 0x80 in
  let () = check_range s ~pos ~len:bytes_consumed in
  let marker = 0x80 lsr (bytes_consumed - 1) in
  let initial = first_byte land (marker - 1) in
  combine_bytes s ~pos ~len:bytes_consumed ~initial ~start_index:1, bytes_consumed

let parse_id s ~pos =
  check_range s ~pos ~len:1;
  let first_byte = get_u8 s pos in
  let bytes_consumed = vint_length first_byte 1 0x80 in
  let () = check_range s ~pos ~len:bytes_consumed in
  combine_bytes s ~pos ~len:bytes_consumed ~initial:first_byte ~start_index:1, bytes_consumed

let unknown_vint_value width = (1 lsl (7 * width)) - 1

let parse_element_header s ~pos =
  let id, id_size = parse_id s ~pos in
  let data_size, data_size_width = parse_vint s ~pos:(pos + id_size) in
  let header_size = id_size + data_size_width in
  let data_size =
    match data_size = unknown_vint_value data_size_width with
    | true -> String.length s - (pos + header_size)
    | false -> data_size
  in
  { id; data_size; header_size; offset = pos }

let get_uint_be s ~pos ~len =
  check_range s ~pos ~len;
  combine_bytes s ~pos ~len ~initial:0 ~start_index:0

let get_u32_be s pos = get_uint_be s ~pos ~len:4

let get_u64_be s pos =
  let rec loop index acc =
    match index = 8 with
    | true -> acc
    | false ->
        let byte = Int64.of_int (get_u8 s (pos + index)) in
        loop (index + 1)
          (Stdlib.Int64.logor (Stdlib.Int64.shift_left acc 8) byte)
  in
  loop 0 Stdlib.Int64.zero

let get_float_be s ~pos ~len =
  match len with
  | 4 -> get_u32_be s pos |> Stdlib.Int32.of_int |> Int32.float_of_bits |> Option.some
  | 8 -> get_u64_be s pos |> Int64.float_of_bits |> Option.some
  | _ -> None

let find_element s ~id ~pos ~limit =
  let end_pos = Int.min (String.length s) (pos + limit) in
  let rec loop current =
    match current >= end_pos || current < pos with
    | true -> None
    | false ->
        let header = parse_element_header s ~pos:current in
        match header.id = id with
        | true -> Some header
        | false ->
            let next_pos = current + header.header_size + header.data_size in
            (match next_pos > end_pos, next_pos <= current with
             | true, _ | _, true -> None
             | false, false -> loop next_pos)
  in
  loop pos

let parse_cue_point s ~pos ~limit =
  let cue_time =
    find_element s ~id:cue_time_id ~pos ~limit
    |> Option.map ~f:(fun header ->
           get_uint_be s ~pos:(header.offset + header.header_size) ~len:header.data_size)
  in
  let cluster_offset =
    find_element s ~id:cue_track_positions_id ~pos ~limit
    |> Option.bind ~f:(fun positions_header ->
           let positions_pos = positions_header.offset + positions_header.header_size in
           find_element s ~id:cue_cluster_position_id ~pos:positions_pos ~limit:positions_header.data_size
           |> Option.map ~f:(fun cluster_header ->
                  get_uint_be s ~pos:(cluster_header.offset + cluster_header.header_size) ~len:cluster_header.data_size))
  in
  match cue_time, cluster_offset with
  | Some cue_time, Some cluster_offset -> Some { cue_time; cluster_offset }
  | _ -> None

let parse_cues s ~pos ~limit =
  let end_pos = Int.min (String.length s) (pos + limit) in
  let rec loop current acc =
    match current >= end_pos with
    | true -> List.rev acc
    | false ->
        let header = parse_element_header s ~pos:current in
        let data_pos = current + header.header_size in
        let next_pos = data_pos + header.data_size in
        let acc =
          match header.id with
          | id when id = cue_point_id ->
              (match parse_cue_point s ~pos:data_pos ~limit:header.data_size with
              | Some cue -> cue :: acc
              | None -> acc)
          | _ -> acc
        in
        match next_pos <= current || next_pos > end_pos with
        | true -> List.rev acc
        | false -> loop next_pos acc
  in
  loop pos []

let parse_segment_info s ~pos ~limit =
  let timecode_scale =
    find_element s ~id:timecode_scale_id ~pos ~limit
    |> Option.map ~f:(fun header ->
           get_uint_be s ~pos:(header.offset + header.header_size) ~len:header.data_size)
    |> Option.value ~default:1_000_000
  in
  let duration_ns =
    find_element s ~id:duration_id ~pos ~limit
    |> Option.bind ~f:(fun header ->
           get_float_be s ~pos:(header.offset + header.header_size) ~len:header.data_size
           |> Option.map ~f:(fun duration ->
                  Float.iround_nearest_exn (duration *. Float.of_int timecode_scale)))
  in
  timecode_scale, duration_ns

let parse_webm_index s =
  let segment =
    find_element s ~id:segment_id ~pos:0 ~limit:(String.length s)
    |> Option.value_exn ~message:"container.ebml: missing Segment element"
  in
  let segment_pos = segment.offset + segment.header_size in
  let segment_limit = segment.data_size in
  let timecode_scale, duration_ns =
    match find_element s ~id:info_id ~pos:segment_pos ~limit:segment_limit with
    | Some info -> parse_segment_info s ~pos:(info.offset + info.header_size) ~limit:info.data_size
    | None -> 1_000_000, None
  in
  let cue_points =
    match find_element s ~id:cues_id ~pos:segment_pos ~limit:segment_limit with
    | Some cues -> parse_cues s ~pos:(cues.offset + cues.header_size) ~limit:cues.data_size
    | None -> []
  in
  { cue_points; timecode_scale; duration_ns }

type seek_entry = {
  target_id: int;
  position: int;
}

(* SeekHead is a sequence of Seek entries. Each Seek has SeekID (binary holding
   the EBML ID of the referenced element) and SeekPosition (uint, byte offset
   from the start of the Segment data section). *)
let parse_seek_id_bytes s ~pos ~len =
  let rec loop i acc =
    match i = len with
    | true -> acc
    | false -> loop (i + 1) ((acc lsl 8) lor get_u8 s (pos + i))
  in
  loop 0 0

let parse_seek s ~pos ~limit =
  let target =
    find_element s ~id:seek_id_id ~pos ~limit
    |> Option.map ~f:(fun h ->
      parse_seek_id_bytes s ~pos:(h.offset + h.header_size) ~len:h.data_size)
  in
  let position =
    find_element s ~id:seek_position_id ~pos ~limit
    |> Option.map ~f:(fun h ->
      get_uint_be s ~pos:(h.offset + h.header_size) ~len:h.data_size)
  in
  match target, position with
  | Some target_id, Some position -> Some { target_id; position }
  | _ -> None

let parse_seek_head s ~pos ~limit =
  let end_pos = Int.min (String.length s) (pos + limit) in
  let rec loop current acc =
    match current >= end_pos with
    | true -> List.rev acc
    | false ->
        let header = parse_element_header s ~pos:current in
        let next_pos = current + header.header_size + header.data_size in
        let acc =
          match header.id = seek_id with
          | true ->
              (match parse_seek s ~pos:(current + header.header_size) ~limit:header.data_size with
               | Some entry -> entry :: acc
               | None -> acc)
          | false -> acc
        in
        (match next_pos <= current || next_pos > end_pos with
         | true -> List.rev acc
         | false -> loop next_pos acc)
  in
  loop pos []

(* Locate the Segment element in [s], returning the position where Segment
   data begins (i.e. just after the Segment header). The size VINT may be
   the "unknown" sentinel; we accept that. *)
let find_segment_data_start s =
  let length = String.length s in
  let segment =
    find_element s ~id:segment_id ~pos:0 ~limit:length
    |> Option.value_exn ~message:"container.ebml: missing Segment element"
  in
  segment.offset + segment.header_size

(* From a buffer containing the head of a WebM file (everything up to and
   including SeekHead/Info/Tracks), locate Cues by walking SeekHead.
   Returns the absolute byte offset (from byte zero of the file) where Cues
   begins, plus the Segment data start (also absolute). *)
let locate_cues_via_seek_head s =
  let segment_data_start = find_segment_data_start s in
  let length = String.length s in
  let seek_head =
    find_element s ~id:seek_head_id ~pos:segment_data_start ~limit:(length - segment_data_start)
    |> Option.value_exn ~message:"container.ebml: missing SeekHead element"
  in
  let entries =
    parse_seek_head s
      ~pos:(seek_head.offset + seek_head.header_size)
      ~limit:seek_head.data_size
  in
  let cues_rel =
    List.find_map entries ~f:(fun e ->
      match e.target_id = cues_id with
      | true -> Some e.position
      | false -> None)
    |> Option.value_exn ~message:"container.ebml: SeekHead has no Cues entry"
  in
  segment_data_start, segment_data_start + cues_rel

(* Parse a stand-alone Cues block (bytes starting at the Cues element header). *)
let parse_cues_block s =
  let header = parse_element_header s ~pos:0 in
  match header.id = cues_id with
  | false -> invalid_arg "container.ebml: expected Cues element"
  | true ->
      parse_cues s
        ~pos:(header.offset + header.header_size)
        ~limit:header.data_size

(* Re-encode an EBML size VINT to the "unknown" sentinel for the given width.
   Used when synthesising a WebM init segment so demuxers keep reading past
   the supplied bytes. *)
let unknown_size_vint width =
  match width with
  | 1 -> "\xFF"
  | 2 -> "\x7F\xFF"
  | 4 -> "\x1F\xFF\xFF\xFF"
  | 8 -> "\x01\xFF\xFF\xFF\xFF\xFF\xFF\xFF"
  | _ -> invalid_arg "container.ebml: unsupported size vint width"

(* WebM Tracks/TrackEntry parsing. Element IDs per the Matroska spec. *)
let tracks_id_v       = tracks_id  (* alias for readability below *)
let track_entry_id    = 0xAE
let track_number_id   = 0xD7
let track_type_id     = 0x83
let codec_id_id       = 0x86
let codec_private_id  = 0x63A2
let codec_delay_id    = 0x56AA      (* nanoseconds *)
let seek_pre_roll_id  = 0x56BB      (* nanoseconds *)
let default_duration_id = 0x23E383  (* nanoseconds per frame *)
let video_element_id  = 0xE0
let pixel_width_id    = 0xB0
let pixel_height_id   = 0xBA
let display_width_id  = 0x54B0
let display_height_id = 0x54BA
let colour_id         = 0x55B0
let colour_range_id            = 0x55B9
let colour_matrix_id           = 0x55B1
let colour_transfer_id         = 0x55BA
let colour_primaries_id        = 0x55BB
let max_cll_id                 = 0x55BC
let max_fall_id                = 0x55BD
let mastering_metadata_id      = 0x55D0
let primary_r_chromaticity_x_id   = 0x55D1
let primary_r_chromaticity_y_id   = 0x55D2
let primary_g_chromaticity_x_id   = 0x55D3
let primary_g_chromaticity_y_id   = 0x55D4
let primary_b_chromaticity_x_id   = 0x55D5
let primary_b_chromaticity_y_id   = 0x55D6
let white_point_chromaticity_x_id = 0x55D7
let white_point_chromaticity_y_id = 0x55D8
let luminance_max_id              = 0x55D9
let luminance_min_id              = 0x55DA
let audio_element_id  = 0xE1
let sampling_freq_id  = 0xB5
let channels_id       = 0x9F
let bit_depth_id      = 0x6264
let cluster_timecode_id = 0xE7
let simple_block_id     = 0xA3
let block_group_id      = 0xA0
let block_id            = 0xA1

type track_kind = Track_video | Track_audio | Track_other of int

let track_kind_of_int = function
  | 1 -> Track_video
  | 2 -> Track_audio
  | n -> Track_other n

type colour = {
  range : int option;
  matrix_coefficients : int option;
  transfer_characteristics : int option;
  primaries : int option;
  max_cll : int option;
  max_fall : int option;
  mastering : mastering option;
}
and mastering = {
  primary_r_x : float option;
  primary_r_y : float option;
  primary_g_x : float option;
  primary_g_y : float option;
  primary_b_x : float option;
  primary_b_y : float option;
  white_x : float option;
  white_y : float option;
  luminance_max : float option;
  luminance_min : float option;
}

type video_track = {
  width : int;
  height : int;
  display_width : int option;
  display_height : int option;
  colour : colour option;
}

type audio_track = {
  sampling_frequency : float;
  channels : int;
  bit_depth : int option;
}

type track_entry = {
  track_number : int;
  kind : track_kind;
  codec_id : string;
  codec_private : string option;
  codec_delay_ns : int option;
  seek_pre_roll_ns : int option;
  default_duration_ns : int option;
  video : video_track option;
  audio : audio_track option;
}

let element_data_pos h = h.offset + h.header_size

let find_uint s ~id ~pos ~limit =
  find_element s ~id ~pos ~limit
  |> Option.map ~f:(fun h ->
       get_uint_be s ~pos:(element_data_pos h) ~len:h.data_size)

let find_float s ~id ~pos ~limit =
  find_element s ~id ~pos ~limit
  |> Option.bind ~f:(fun h ->
       get_float_be s ~pos:(element_data_pos h) ~len:h.data_size)

let find_bytes s ~id ~pos ~limit =
  find_element s ~id ~pos ~limit
  |> Option.map ~f:(fun h ->
       String.sub s ~pos:(element_data_pos h) ~len:h.data_size)

let find_string s ~id ~pos ~limit = find_bytes s ~id ~pos ~limit

let parse_mastering s ~pos ~limit =
  let f id = find_float s ~id ~pos ~limit in
  Some {
    primary_r_x = f primary_r_chromaticity_x_id;
    primary_r_y = f primary_r_chromaticity_y_id;
    primary_g_x = f primary_g_chromaticity_x_id;
    primary_g_y = f primary_g_chromaticity_y_id;
    primary_b_x = f primary_b_chromaticity_x_id;
    primary_b_y = f primary_b_chromaticity_y_id;
    white_x = f white_point_chromaticity_x_id;
    white_y = f white_point_chromaticity_y_id;
    luminance_max = f luminance_max_id;
    luminance_min = f luminance_min_id;
  }

let parse_colour s ~pos ~limit =
  let u id = find_uint s ~id ~pos ~limit in
  let mastering =
    find_element s ~id:mastering_metadata_id ~pos ~limit
    |> Option.bind ~f:(fun h ->
         parse_mastering s ~pos:(element_data_pos h) ~limit:h.data_size)
  in
  Some {
    range = u colour_range_id;
    matrix_coefficients = u colour_matrix_id;
    transfer_characteristics = u colour_transfer_id;
    primaries = u colour_primaries_id;
    max_cll = u max_cll_id;
    max_fall = u max_fall_id;
    mastering;
  }

let parse_video s ~pos ~limit =
  let width = find_uint s ~id:pixel_width_id ~pos ~limit in
  let height = find_uint s ~id:pixel_height_id ~pos ~limit in
  let colour =
    find_element s ~id:colour_id ~pos ~limit
    |> Option.bind ~f:(fun h ->
         parse_colour s ~pos:(element_data_pos h) ~limit:h.data_size)
  in
  match width, height with
  | Some width, Some height ->
      Some {
        width; height;
        display_width  = find_uint s ~id:display_width_id  ~pos ~limit;
        display_height = find_uint s ~id:display_height_id ~pos ~limit;
        colour;
      }
  | _ -> None

let parse_audio s ~pos ~limit =
  let sampling_frequency =
    find_float s ~id:sampling_freq_id ~pos ~limit
    |> Option.value ~default:8000.0
  in
  let channels = find_uint s ~id:channels_id ~pos ~limit |> Option.value ~default:1 in
  let bit_depth = find_uint s ~id:bit_depth_id ~pos ~limit in
  Some { sampling_frequency; channels; bit_depth }

let parse_track_entry s ~pos ~limit =
  let track_number =
    find_uint s ~id:track_number_id ~pos ~limit
    |> Option.value_exn ~message:"container.ebml: TrackEntry missing TrackNumber"
  in
  let kind =
    find_uint s ~id:track_type_id ~pos ~limit
    |> Option.value_exn ~message:"container.ebml: TrackEntry missing TrackType"
    |> track_kind_of_int
  in
  let codec_id =
    find_string s ~id:codec_id_id ~pos ~limit
    |> Option.value_exn ~message:"container.ebml: TrackEntry missing CodecID"
  in
  let codec_private = find_bytes s ~id:codec_private_id ~pos ~limit in
  let codec_delay_ns = find_uint s ~id:codec_delay_id ~pos ~limit in
  let seek_pre_roll_ns = find_uint s ~id:seek_pre_roll_id ~pos ~limit in
  let default_duration_ns = find_uint s ~id:default_duration_id ~pos ~limit in
  let video =
    find_element s ~id:video_element_id ~pos ~limit
    |> Option.bind ~f:(fun h ->
         parse_video s ~pos:(element_data_pos h) ~limit:h.data_size)
  in
  let audio =
    find_element s ~id:audio_element_id ~pos ~limit
    |> Option.bind ~f:(fun h ->
         parse_audio s ~pos:(element_data_pos h) ~limit:h.data_size)
  in
  { track_number; kind; codec_id; codec_private;
    codec_delay_ns; seek_pre_roll_ns; default_duration_ns;
    video; audio }

let parse_tracks s ~pos ~limit =
  let end_pos = Int.min (String.length s) (pos + limit) in
  let rec loop current acc =
    match current >= end_pos with
    | true -> List.rev acc
    | false ->
        let h = parse_element_header s ~pos:current in
        let next = current + h.header_size + h.data_size in
        let acc =
          match h.id = track_entry_id with
          | true -> parse_track_entry s ~pos:(element_data_pos h) ~limit:h.data_size :: acc
          | false -> acc
        in
        match next <= current || next > end_pos with
        | true -> List.rev acc
        | false -> loop next acc
  in
  loop pos []

(* Cluster + SimpleBlock parsing.

   Cluster element starts with Timecode (relative to segment timecode scale),
   followed by SimpleBlock / BlockGroup children. SimpleBlock has structure:
     [track-number vint] [signed int16 BE timecode delta] [u8 flags] [frame bytes]
   We only support single-frame (non-lacing) SimpleBlocks — YouTube uses these. *)

type simple_block = {
  track_number : int;
  timecode_delta : int;
  keyframe : bool;
  frame_offset : int;     (* absolute offset of frame bytes in [s] *)
  frame_len : int;
}

type cluster = {
  timecode : int;
  data_pos : int;
  data_end : int;
}

let parse_cluster_header s ~pos =
  let h = parse_element_header s ~pos in
  match h.id = cluster_id with
  | false -> invalid_arg "container.ebml: expected Cluster element"
  | true ->
      let data_pos = element_data_pos h in
      let data_end = data_pos + h.data_size in
      let timecode =
        find_uint s ~id:cluster_timecode_id ~pos:data_pos ~limit:h.data_size
        |> Option.value_exn ~message:"container.ebml: Cluster missing Timecode"
      in
      { timecode; data_pos; data_end }

let get_i16_be s pos =
  let v = (get_u8 s pos lsl 8) lor (get_u8 s (pos + 1)) in
  match v >= 0x8000 with
  | true -> v - 0x10000
  | false -> v

let parse_simple_block_body s ~pos ~data_size =
  let tn, tn_w = parse_vint s ~pos in
  let tc_pos = pos + tn_w in
  let timecode_delta = get_i16_be s tc_pos in
  let flags = get_u8 s (tc_pos + 2) in
  let lacing = (flags lsr 1) land 0x03 in
  match lacing <> 0 with
  | true -> invalid_arg "container.ebml: laced SimpleBlock not supported"
  | false ->
      let frame_offset = tc_pos + 3 in
      let frame_len = data_size - (frame_offset - pos) in
      let keyframe = (flags land 0x80) <> 0 in
      { track_number = tn; timecode_delta; keyframe; frame_offset; frame_len }

let parse_block_group_simple s ~pos ~limit =
  (* For BlockGroup, decode the contained Block (0xA1) the same way as
     SimpleBlock. Keyframe flag is not in Block; treat as non-keyframe. *)
  find_element s ~id:block_id ~pos ~limit
  |> Option.map ~f:(fun h ->
       let sb = parse_simple_block_body s ~pos:(element_data_pos h) ~data_size:h.data_size in
       { sb with keyframe = false })

let parse_cluster_blocks s (c : cluster) =
  let rec loop current acc =
    match current >= c.data_end with
    | true -> List.rev acc
    | false ->
        let h = parse_element_header s ~pos:current in
        let next = current + h.header_size + h.data_size in
        let acc =
          match h.id with
          | id when id = simple_block_id ->
              parse_simple_block_body s ~pos:(element_data_pos h) ~data_size:h.data_size :: acc
          | id when id = block_group_id ->
              (match parse_block_group_simple s ~pos:(element_data_pos h) ~limit:h.data_size with
               | Some sb -> sb :: acc
               | None -> acc)
          | _ -> acc
        in
        match next <= current || next > c.data_end with
        | true -> List.rev acc
        | false -> loop next acc
  in
  loop c.data_pos []

let _ = tracks_id_v

let webm_init_from_pieces ~ebml_bytes ~info_bytes ~tracks_bytes =
  let segment_id_bytes = "\x18\x53\x80\x67" in
  let size_vint = unknown_size_vint 8 in
  String.concat [ ebml_bytes; segment_id_bytes; size_vint; info_bytes; tracks_bytes ]

(* Build a WebM init blob from head bytes: keep EBML header, Segment header
   (with size rewritten to unknown), Info, Tracks. *)
let build_webm_init s =
  let length = String.length s in
  let ebml_header =
    find_element s ~id:0x1A45_DFA3 ~pos:0 ~limit:length
    |> Option.value_exn ~message:"container.ebml: missing EBML header"
  in
  let segment =
    find_element s ~id:segment_id ~pos:0 ~limit:length
    |> Option.value_exn ~message:"container.ebml: missing Segment element"
  in
  let segment_data_start = segment.offset + segment.header_size in
  let info =
    find_element s ~id:info_id ~pos:segment_data_start ~limit:segment.data_size
    |> Option.value_exn ~message:"container.ebml: missing Info element"
  in
  let tracks =
    find_element s ~id:tracks_id ~pos:segment_data_start ~limit:segment.data_size
    |> Option.value_exn ~message:"container.ebml: missing Tracks element"
  in
  let info_bytes =
    String.sub s ~pos:info.offset ~len:(info.header_size + info.data_size)
  in
  let tracks_bytes =
    String.sub s ~pos:tracks.offset ~len:(tracks.header_size + tracks.data_size)
  in
  let ebml_bytes =
    String.sub s ~pos:ebml_header.offset
      ~len:(ebml_header.header_size + ebml_header.data_size)
  in
  let segment_id_bytes = "\x18\x53\x80\x67" in
  let size_vint = unknown_size_vint 8 in
  String.concat [ ebml_bytes; segment_id_bytes; size_vint; info_bytes; tracks_bytes ]


let%expect_test "parse_vint handles one and two byte values" =
  let value_1, width_1 = parse_vint "\130" ~pos:0 in
  let value_2, width_2 = parse_vint "\064\000" ~pos:0 in
  Stdlib.Printf.printf "%d %d\n%d %d\n" value_1 width_1 value_2 width_2;
  [%expect {|
    2 1
    0 2
  |}]
