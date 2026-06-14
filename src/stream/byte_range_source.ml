
open! Base
open Util

(** Shared scaffolding for sources that fetch fixed-byte-range segments over
    HTTP — VOD fMP4, VOD WebM, and any future container that maps onto a flat
    [(offset, length, duration)] list known up front.

    State is parameterised on the producer kind so a [Producer.video t] is
    type-guaranteed to carry a [Video _] track at runtime. *)

type parsed = {
  total_length : int;
  init_bytes   : string;
  segments     : Producer.Segment_info.t array;
  offsets      : int array;
}

type 'k state = {
  client       : Http_client.t;
  clock        : float Eio.Time.clock_ty Eio.Resource.t;
  url          : string;
  headers      : (string * string) list;
  total_length : int;
  init_bytes   : string;
  segments     : Producer.Segment_info.t array;
  offsets      : int array;
  meta         : Producer.Meta.t;
}

module Log = (val Util.Log_src.src_log ~doc:"byte-range segment source" Stdlib.__MODULE__)

let total_duration_usec segs =
  Array.fold segs ~init:0 ~f:(fun acc (i : Producer.Segment_info.t) ->
    acc + i.length_usec)

module type Format = sig
  val container : Producer.Container.kind
  val parse
    :  Http_client.t
    -> string
    -> headers:(string * string) list
    -> parsed
end

module Make (F : Format) = struct
  type video_state = Producer.video state
  type audio_state = Producer.audio state

  let create_video ~headers ~clock ~client ~url ~codec ~dynamic_range ~rfc6381 ()
    : (module Producer.S with type kind = Producer.video) =
    (module struct
      type state = video_state
      type kind = Producer.video
      let witness = Producer.Kind.Video

      let init ~env:_ ~sw:_ ~target:_ =
        let p = F.parse client url ~headers in
        let meta : Producer.Meta.t = {
          total_duration_usec = Some (total_duration_usec p.segments);
          start_walltime_ms = 0;
          is_live = false;
        } in
        let shape : Producer.video Producer.Shape.t =
          Producer.Shape.Video { container = F.container; codec; dynamic_range; rfc6381 }
        in
        { client; clock; url; headers;
          total_length = p.total_length;
          init_bytes   = p.init_bytes;
          segments     = p.segments;
          offsets      = p.offsets;
          meta }, shape

      let meta s = s.meta
      let init_segment s = s.init_bytes
      let segments s = Producer.Segments.Known s.segments
      let max_segment_id s = Array.length s.segments - 1
      let close _ = ()

      let fetch_segment s ~id =
        match id < 0 || id >= Array.length s.segments with
        | true ->
            Producer.Error.raise_error
              (Producer.Error.Parse_error
                 (Printf.sprintf "segment id %d out of range" id))
        | false ->
            let info = s.segments.(id) in
            let offset = s.offsets.(id) in
            let range =
              Stdlib.Printf.sprintf "bytes=%d-%d" offset
                (offset + info.byte_length - 1)
            in
            let t0 = Eio.Time.now s.clock in
            let data, _ =
              Http_range.fetch s.client s.url
                ~headers:(("Range", range) :: s.headers)
                ~start:offset ~len:info.byte_length ()
              |> Producer.Error.lift_http_range
              |> Producer.Error.unwrap
            in
            let elapsed_ms = (Eio.Time.now s.clock -. t0) *. 1000.0 in
            Log.info (fun m ->
              m "%s" (Producer.fetch_summary ~kind:"video" ~id ~bytes:(String.length data) ~elapsed_ms));
            { Producer.Segment.start_usec = info.start_usec;
              length_usec = info.length_usec;
              data }
    end)

  let create_audio ~headers ~clock ~client ~url ~codec ~rfc6381 ()
    : (module Producer.S with type kind = Producer.audio) =
    (module struct
      type state = audio_state
      type kind = Producer.audio
      let witness = Producer.Kind.Audio

      let init ~env:_ ~sw:_ ~target:_ =
        let p = F.parse client url ~headers in
        let meta : Producer.Meta.t = {
          total_duration_usec = Some (total_duration_usec p.segments);
          start_walltime_ms = 0;
          is_live = false;
        } in
        let shape : Producer.audio Producer.Shape.t =
          Producer.Shape.Audio { container = F.container; codec; rfc6381 }
        in
        { client; clock; url; headers;
          total_length = p.total_length;
          init_bytes   = p.init_bytes;
          segments     = p.segments;
          offsets      = p.offsets;
          meta }, shape

      let meta s = s.meta
      let init_segment s = s.init_bytes
      let segments s = Producer.Segments.Known s.segments
      let max_segment_id s = Array.length s.segments - 1
      let close _ = ()

      let fetch_segment s ~id =
        match id < 0 || id >= Array.length s.segments with
        | true ->
            Producer.Error.raise_error
              (Producer.Error.Parse_error
                 (Printf.sprintf "segment id %d out of range" id))
        | false ->
            let info = s.segments.(id) in
            let offset = s.offsets.(id) in
            let range =
              Stdlib.Printf.sprintf "bytes=%d-%d" offset
                (offset + info.byte_length - 1)
            in
            let t0 = Eio.Time.now s.clock in
            let data, _ =
              Http_range.fetch s.client s.url
                ~headers:(("Range", range) :: s.headers)
                ~start:offset ~len:info.byte_length ()
              |> Producer.Error.lift_http_range
              |> Producer.Error.unwrap
            in
            let elapsed_ms = (Eio.Time.now s.clock -. t0) *. 1000.0 in
            Log.info (fun m ->
              m "%s" (Producer.fetch_summary ~kind:"audio" ~id ~bytes:(String.length data) ~elapsed_ms));
            { Producer.Segment.start_usec = info.start_usec;
              length_usec = info.length_usec;
              data }
    end)
end
