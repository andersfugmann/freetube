open! Base

(** fMP4 box writers and sample-entry helpers used by the WebM→fMP4 remuxer.

    Everything is byte-oriented and pure. A "box" is [size:u32][type:4
    bytes][payload]; a "full box" prepends [version:u8][flags:u24] to the
    payload. We never need 64-bit sizes — segments are well under 4 GiB.

    See ISO/IEC 14496-12 (ISOBMFF base), 14496-14 (mp4 box layout),
    AV1-ISOBMFF (Alliance), VP-Codec-ISOBMFF (vp09), and the Opus-in-ISOBMFF
    spec for the per-codec sample entries. *)

let u8 = Stdlib.Buffer.add_uint8
let u16 = Stdlib.Buffer.add_uint16_be
let u32 b v = Stdlib.Buffer.add_int32_be b (Int32.of_int_trunc v)
let u64 b v = Stdlib.Buffer.add_int64_be b (Int64.of_int v)
let s16 = Stdlib.Buffer.add_int16_be
let s32 b v = Stdlib.Buffer.add_int32_be b (Int32.of_int_trunc v)

let u24 b v =
  u8 b (v lsr 16); u16 b v

let bytes b s = Buffer.add_string b s

let four_cc b s =
  match String.length s <> 4 with
  | true -> invalid_arg (Printf.sprintf "bmff.builder: four_cc %S" s)
  | false -> Buffer.add_string b s

(** [box ~ty payload] = [size:u32][type:4][payload]. *)
let box ~ty payload =
  let len = 8 + String.length payload in
  let b = Buffer.create len in
  u32 b len; four_cc b ty; bytes b payload;
  Buffer.contents b

(** [full_box ~ty ~version ~flags payload] prepends version/flags. *)
let full_box ~ty ~version ~flags payload =
  let b = Buffer.create (String.length payload + 4) in
  u8 b version; u24 b flags; bytes b payload;
  box ~ty (Buffer.contents b)

let concat parts = String.concat ~sep:"" parts

(* ---------- top-level boxes ---------- *)

let ftyp ~major ~minor ~compatible =
  let b = Buffer.create 32 in
  four_cc b major; u32 b minor;
  List.iter compatible ~f:(four_cc b);
  box ~ty:"ftyp" (Buffer.contents b)

let mvhd ~timescale ~duration ~next_track_id =
  let b = Buffer.create 96 in
  u32 b 0;             (* creation time *)
  u32 b 0;             (* modification time *)
  u32 b timescale;
  u32 b duration;
  u32 b 0x0001_0000;   (* rate 1.0 *)
  u16 b 0x0100;        (* volume 1.0 *)
  u16 b 0;             (* reserved *)
  u32 b 0; u32 b 0;    (* reserved *)
  (* unity matrix *)
  List.iter [0x10000;0;0; 0;0x10000;0; 0;0;0x40000000]
    ~f:(u32 b);
  (* pre_defined[6] *)
  for _ = 1 to 6 do u32 b 0 done;
  u32 b next_track_id;
  full_box ~ty:"mvhd" ~version:0 ~flags:0 (Buffer.contents b)

let tkhd ~track_id ~duration ~width ~height ~is_video =
  let b = Buffer.create 96 in
  u32 b 0;             (* creation_time *)
  u32 b 0;             (* modification_time *)
  u32 b track_id;
  u32 b 0;             (* reserved *)
  u32 b duration;
  u32 b 0; u32 b 0;    (* reserved *)
  u16 b 0;             (* layer *)
  u16 b 0;             (* alternate_group *)
  u16 b (match is_video with true -> 0 | false -> 0x0100); (* volume: 1.0 for audio *)
  u16 b 0;
  List.iter [0x10000;0;0; 0;0x10000;0; 0;0;0x40000000] ~f:(u32 b);
  (* width / height in 16.16 fixed *)
  u32 b (width  lsl 16);
  u32 b (height lsl 16);
  full_box ~ty:"tkhd" ~version:0 ~flags:0x000007 (Buffer.contents b)

let mdhd ~timescale ~duration =
  let b = Buffer.create 32 in
  u32 b 0; u32 b 0;
  u32 b timescale;
  u32 b duration;
  u16 b 0x55c4;        (* language = und *)
  u16 b 0;             (* pre_defined *)
  full_box ~ty:"mdhd" ~version:0 ~flags:0 (Buffer.contents b)

let hdlr ~handler_type ~name =
  let b = Buffer.create 32 in
  u32 b 0;             (* pre_defined *)
  four_cc b handler_type;
  u32 b 0; u32 b 0; u32 b 0;
  Buffer.add_string b name;
  Buffer.add_char b '\x00';
  full_box ~ty:"hdlr" ~version:0 ~flags:0 (Buffer.contents b)

let vmhd =
  let b = Buffer.create 8 in
  u16 b 0;             (* graphicsmode *)
  u16 b 0; u16 b 0; u16 b 0;  (* opcolor *)
  full_box ~ty:"vmhd" ~version:0 ~flags:0x000001 (Buffer.contents b)

let smhd =
  let b = Buffer.create 4 in
  u16 b 0;             (* balance *)
  u16 b 0;
  full_box ~ty:"smhd" ~version:0 ~flags:0 (Buffer.contents b)

let dref =
  let b = Buffer.create 16 in
  u32 b 1;             (* entry_count *)
  Buffer.add_string b (full_box ~ty:"url " ~version:0 ~flags:0x000001 "");
  full_box ~ty:"dref" ~version:0 ~flags:0 (Buffer.contents b)

let dinf = box ~ty:"dinf" dref

(* ---------- sample entries ---------- *)

let visual_sample_entry ~four_cc:fcc ~width ~height ~ext_boxes =
  let b = Buffer.create 78 in
  u8 b 0; u8 b 0; u8 b 0; u8 b 0; u8 b 0; u8 b 0;  (* reserved[6] *)
  u16 b 1;             (* data_reference_index *)
  u16 b 0;             (* pre_defined *)
  u16 b 0;             (* reserved *)
  u32 b 0; u32 b 0; u32 b 0;
  u16 b width;
  u16 b height;
  u32 b 0x0048_0000;   (* horizresolution 72 dpi *)
  u32 b 0x0048_0000;
  u32 b 0;             (* reserved *)
  u16 b 1;             (* frame_count *)
  for _ = 1 to 32 do u8 b 0 done;  (* compressorname[32] *)
  u16 b 0x0018;        (* depth = 24 *)
  s16 b (-1);          (* pre_defined *)
  List.iter ext_boxes ~f:(Buffer.add_string b);
  box ~ty:fcc (Buffer.contents b)

let audio_sample_entry ~four_cc:fcc ~channels ~sample_rate ~ext_boxes =
  let b = Buffer.create 28 in
  u8 b 0; u8 b 0; u8 b 0; u8 b 0; u8 b 0; u8 b 0;
  u16 b 1;             (* data_reference_index *)
  u32 b 0; u32 b 0;    (* reserved *)
  u16 b channels;
  u16 b 16;            (* samplesize *)
  u16 b 0;             (* pre_defined *)
  u16 b 0;             (* reserved *)
  u32 b (sample_rate lsl 16);  (* 16.16 fixed *)
  List.iter ext_boxes ~f:(Buffer.add_string b);
  box ~ty:fcc (Buffer.contents b)

let av1c ~config_obus =
  (* av1C carries the AV1CodecConfigurationRecord verbatim. WebM CodecPrivate
     for V_AV1 already contains this record (marker bit set, version 1, plus
     the configOBUs). We pass it through unchanged. *)
  box ~ty:"av1C" config_obus

let vpcc ~profile ~level ~bit_depth ~chroma_subsampling
        ~video_full_range ~colour_primaries ~transfer_characteristics
        ~matrix_coefficients =
  let b = Buffer.create 12 in
  u8 b profile;
  u8 b level;
  let byte =
    ((bit_depth land 0x0f) lsl 4)
    lor ((chroma_subsampling land 0x07) lsl 1)
    lor (match video_full_range with true -> 1 | false -> 0)
  in
  u8 b byte;
  u8 b colour_primaries;
  u8 b transfer_characteristics;
  u8 b matrix_coefficients;
  u16 b 0;             (* codec_initialization_data_size = 0 *)
  full_box ~ty:"vpcC" ~version:1 ~flags:0 (Buffer.contents b)

let dops_from_opus_head opus_head =
  (* OpusHead (WebM CodecPrivate) layout:
       "OpusHead" (8) | version u8 | channels u8 | preskip u16le |
       input_sample_rate u32le | output_gain s16le | mapping_family u8 | [tail]
     dOps wants the same fields but BIG-ENDIAN and WITHOUT the magic. We strip
     the leading "OpusHead" and byte-swap. *)
  match String.length opus_head >= 19 && String.is_prefix opus_head ~prefix:"OpusHead" with
  | false -> invalid_arg "bmff.builder: malformed OpusHead"
  | true ->
      let get_u8' p = Char.to_int (String.get opus_head p) in
      let get_u16_le p = get_u8' p lor (get_u8' (p+1) lsl 8) in
      let get_u32_le p =
        get_u8' p lor (get_u8' (p+1) lsl 8)
        lor (get_u8' (p+2) lsl 16) lor (get_u8' (p+3) lsl 24)
      in
      let version = get_u8' 8 in
      let _ = version in
      let channels = get_u8' 9 in
      let preskip = get_u16_le 10 in
      let input_sample_rate = get_u32_le 12 in
      let output_gain =
        let raw = get_u16_le 16 in
        match raw >= 0x8000 with true -> raw - 0x10000 | false -> raw
      in
      let mapping_family = get_u8' 18 in
      let b = Buffer.create 19 in
      u8 b 0;                 (* dOps Version is always 0 *)
      u8 b channels;
      u16 b preskip;
      u32 b input_sample_rate;
      s16 b output_gain;
      u8 b mapping_family;
      (match mapping_family <> 0, String.length opus_head >= 19 + 2 + channels with
       | true, true ->
           Buffer.add_string b
             (String.sub opus_head ~pos:19 ~len:(2 + channels))
       | true, false -> invalid_arg "bmff.builder: OpusHead mapping table truncated"
       | false, _ -> ());
      box ~ty:"dOps" (Buffer.contents b)

(* ---------- stsd / stbl / minf / mdia ---------- *)

let stsd entries =
  let b = Buffer.create 16 in
  u32 b (List.length entries);
  List.iter entries ~f:(Buffer.add_string b);
  full_box ~ty:"stsd" ~version:0 ~flags:0 (Buffer.contents b)

let empty_full_box ty =
  let b = Buffer.create 8 in
  u32 b 0;             (* entry_count = 0 *)
  full_box ~ty ~version:0 ~flags:0 (Buffer.contents b)

let stts_empty = empty_full_box "stts"
let stsc_empty = empty_full_box "stsc"
let stco_empty = empty_full_box "stco"

let stsz_empty =
  let b = Buffer.create 8 in
  u32 b 0;             (* sample_size = 0 (variable) *)
  u32 b 0;             (* sample_count = 0 *)
  full_box ~ty:"stsz" ~version:0 ~flags:0 (Buffer.contents b)

let stbl ~sample_entry =
  box ~ty:"stbl"
    (concat [ stsd [sample_entry]; stts_empty; stsc_empty; stsz_empty; stco_empty ])

let minf ~is_video ~stbl_bytes =
  let header = match is_video with true -> vmhd | false -> smhd in
  box ~ty:"minf" (concat [ header; dinf; stbl_bytes ])

let mdia ~timescale ~duration ~handler_type ~hdlr_name ~minf_bytes =
  box ~ty:"mdia"
    (concat [ mdhd ~timescale ~duration;
              hdlr ~handler_type ~name:hdlr_name;
              minf_bytes ])

let elst_preskip ~timescale ~skip_samples ~media_duration =
  (* One edit list entry: skip the pre-skip samples. *)
  let b = Buffer.create 20 in
  u32 b 1;
  let _ = timescale in
  (* segment_duration in movie timescale; we use media timescale for both *)
  u32 b media_duration;
  s32 b skip_samples;  (* media_time *)
  u16 b 1; u16 b 0;    (* media_rate_integer / fraction *)
  full_box ~ty:"elst" ~version:0 ~flags:0 (Buffer.contents b)

let edts_preskip ~timescale ~skip_samples ~media_duration =
  box ~ty:"edts" (elst_preskip ~timescale ~skip_samples ~media_duration)

let trak ?edts ~track_id ~duration ~width ~height ~is_video ~mdia_bytes () =
  let tkhd_b = tkhd ~track_id ~duration ~width ~height ~is_video in
  let parts =
    match edts with
    | Some e -> [ tkhd_b; e; mdia_bytes ]
    | None   -> [ tkhd_b; mdia_bytes ]
  in
  box ~ty:"trak" (concat parts)

let trex ~track_id =
  let b = Buffer.create 24 in
  u32 b track_id;
  u32 b 1;             (* default_sample_description_index *)
  u32 b 0;             (* default_sample_duration *)
  u32 b 0;             (* default_sample_size *)
  u32 b 0;             (* default_sample_flags *)
  full_box ~ty:"trex" ~version:0 ~flags:0 (Buffer.contents b)

let mvex ~track_id =
  box ~ty:"mvex" (trex ~track_id)

let moov ~timescale ~duration ~trak_bytes ~track_id =
  box ~ty:"moov"
    (concat [ mvhd ~timescale ~duration ~next_track_id:(track_id + 1);
              trak_bytes;
              mvex ~track_id ])

(* ---------- moof / mdat ---------- *)

type sample = {
  duration : int;     (* in media timescale *)
  size : int;
  flags : int;        (* tf_sample_flags (see spec); 0 = unspecified *)
  is_keyframe : bool;
}

let default_sample_flag_keyframe = 0x0200_0000  (* sample_depends_on=2 (no others depend) *)
let default_sample_flag_non_key  = 0x0101_0000  (* is_non_sync_sample=1 *)

let trun ~data_offset ~samples =
  let n = List.length samples in
  (* flags: 0x000001 data_offset_present | 0x000100 duration | 0x000200 size
     | 0x000400 sample_flags | 0x000800 cts_offset (we don't set CTS) *)
  let flags = 0x0001 lor 0x0100 lor 0x0200 lor 0x0400 in
  let b = Buffer.create (12 + n * 16) in
  u32 b n;
  s32 b data_offset;
  List.iter samples ~f:(fun (s : sample) ->
    u32 b s.duration;
    u32 b s.size;
    let sample_flags =
      match s.is_keyframe with
      | true  -> default_sample_flag_keyframe
      | false -> default_sample_flag_non_key
    in
    u32 b sample_flags);
  full_box ~ty:"trun" ~version:0 ~flags (Buffer.contents b)

let tfhd ~track_id =
  (* flags=0x020000 default-base-is-moof; no defaults supplied *)
  let b = Buffer.create 4 in
  u32 b track_id;
  full_box ~ty:"tfhd" ~version:0 ~flags:0x020000 (Buffer.contents b)

let tfdt ~base_media_decode_time =
  let b = Buffer.create 8 in
  u64 b base_media_decode_time;
  full_box ~ty:"tfdt" ~version:1 ~flags:0 (Buffer.contents b)

let mfhd ~sequence =
  let b = Buffer.create 4 in
  u32 b sequence;
  full_box ~ty:"mfhd" ~version:0 ~flags:0 (Buffer.contents b)

(** Build a single-track fragment.

    Returns [moof ^ mdat] where moof's trun.data_offset points at the first
    byte of mdat payload (computed by laying out moof first to know its size,
    then patching trun.data_offset). *)
let build_fragment ~sequence ~track_id ~base_decode_time ~samples ~payload =
  let traf body = box ~ty:"traf" body in
  let make_moof ~data_offset =
    let traf_body =
      concat [ tfhd ~track_id; tfdt ~base_media_decode_time:base_decode_time;
               trun ~data_offset ~samples ]
    in
    box ~ty:"moof" (concat [ mfhd ~sequence; traf traf_body ])
  in
  (* First pass with placeholder offset to learn moof length. *)
  let moof_probe = make_moof ~data_offset:0 in
  let moof_len = String.length moof_probe in
  let data_offset = moof_len + 8 in   (* mdat header is 8 bytes *)
  let moof_final = make_moof ~data_offset in
  let mdat = box ~ty:"mdat" payload in
  moof_final ^ mdat

(* ---------- top-level init builders ---------- *)

let build_audio_init ~four_cc:fcc ~ext_boxes ~timescale ~channels ~sample_rate
    ~track_id ?edts () =
  let sample_entry =
    audio_sample_entry ~four_cc:fcc ~channels ~sample_rate ~ext_boxes
  in
  let mdia_bytes =
    mdia ~timescale ~duration:0 ~handler_type:"soun" ~hdlr_name:"SoundHandler"
      ~minf_bytes:(minf ~is_video:false ~stbl_bytes:(stbl ~sample_entry))
  in
  let trak_bytes =
    trak ?edts ~track_id ~duration:0 ~width:0 ~height:0 ~is_video:false
      ~mdia_bytes ()
  in
  let ftyp_b = ftyp ~major:"iso6" ~minor:0
                ~compatible:["iso6"; "iso5"; "dash"; "cmfc"] in
  let moov_b = moov ~timescale ~duration:0 ~trak_bytes ~track_id in
  ftyp_b ^ moov_b

let build_video_init ~four_cc:fcc ~ext_boxes ~timescale ~width ~height ~track_id =
  let sample_entry =
    visual_sample_entry ~four_cc:fcc ~width ~height ~ext_boxes
  in
  let mdia_bytes =
    mdia ~timescale ~duration:0 ~handler_type:"vide" ~hdlr_name:"VideoHandler"
      ~minf_bytes:(minf ~is_video:true ~stbl_bytes:(stbl ~sample_entry))
  in
  let trak_bytes =
    trak ~track_id ~duration:0 ~width ~height ~is_video:true ~mdia_bytes ()
  in
  let ftyp_b = ftyp ~major:"iso6" ~minor:0
                ~compatible:["iso6"; "iso5"; "dash"; "cmfc"] in
  let moov_b = moov ~timescale ~duration:0 ~trak_bytes ~track_id in
  ftyp_b ^ moov_b
