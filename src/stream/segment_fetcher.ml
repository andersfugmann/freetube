open! Base
open Util

module Log = (val Log_src.src_log ~doc:"Segment-based stream fetcher" Stdlib.__MODULE__)

let stale_threshold () = (Config.get ()).streaming.segment_stale_threshold_seconds
let window_seconds () = (Config.get ()).streaming.live_window_seconds

type 'k state = {
  client          : Http_client.t;
  clock           : float Eio.Time.clock_ty Eio.Resource.t;
  url             : string;
  headers         : (string * string) list;
  container       : Producer.Container.kind;
  is_live         : bool;
  mutable head_seqnum      : int;
  mutable head_time_millis : int;
  mutable walltime_ms      : int;
  mutable last_fetch       : float;
  mutable init_raw         : string option;
}

let segment_duration_usec s =
  match s.head_seqnum > 0 with
  | true -> s.head_time_millis * 1000 / s.head_seqnum
  | false -> 5_000_000

let start_seqnum s =
  let dur = segment_duration_usec s in
  let window_count =
    match dur > 0 with
    | true -> window_seconds () * 1_000_000 / dur
    | false -> 2160
  in
  Int.max 0 (s.head_seqnum - window_count)

let is_stale s =
  Float.(Eio.Time.now s.clock -. s.last_fetch > stale_threshold ())

let update_head s (response : Http_client.response) =
  let headers = List.map ~f:(fun (h, v) -> (String.lowercase h, v)) response.headers in
  let find_int_header headers name =
    let name = String.lowercase name in
    List.Assoc.find headers name ~equal:String.equal
    |> Option.bind ~f:Int.of_string_opt
  in
  let seq =
    find_int_header headers "x-head-seqnum"
    |> Option.value ~default:s.head_seqnum
  in
  let time =
    find_int_header headers "x-head-time-millis"
    |> Option.value ~default:s.head_time_millis
  in
  let wt =
    find_int_header headers "x-walltime-ms"
    |> Option.value ~default:s.walltime_ms
  in
  s.head_seqnum <- seq;
  s.head_time_millis <- time;
  s.walltime_ms <- wt;
  s.last_fetch <- Eio.Time.now s.clock

let do_head s =
  let uri = Uri.of_string s.url in
  let t0 = Eio.Time.now s.clock in
  let response = Http_client.head s.client ~ip_version:`V6 ~headers:s.headers uri in
  let elapsed_ms = (Eio.Time.now s.clock -. t0) *. 1000.0 in
  Log.info (fun m -> m "HEAD %s status=%d time=%dms" s.url response.status (Float.to_int elapsed_ms));
  match response.status with
  | 200 -> update_head s response
  | code ->
      Producer.Error.raise_error
        (Producer.Error.Source_unavailable (Printf.sprintf "HEAD returned %d" code))

let ensure_head s =
  match s.head_seqnum = 0 || is_stale s with
  | true -> do_head s
  | false -> ()

let fetch_raw s ~sq =
  let sq_url = Printf.sprintf "%s&sq=%d" s.url sq in
  let uri = Uri.of_string sq_url in
  let response = Http_client.get s.client ~ip_version:`V6 ~headers:s.headers uri in
  update_head s response;
  match response.status with
  | 200 -> response.body
  | 403 ->
      Producer.Error.raise_error
        (Producer.Error.Source_unavailable "url expired (http 403)")
  | code ->
      Producer.Error.raise_error
        (Producer.Error.Source_unavailable (Printf.sprintf "http %d" code))

let fetch_latest s =
  let uri = Uri.of_string s.url in
  let response = Http_client.get s.client ~ip_version:`V6 ~headers:s.headers uri in
  update_head s response;
  match response.status with
  | 200 -> response.body
  | 403 ->
      Producer.Error.raise_error
        (Producer.Error.Source_unavailable "url expired (http 403)")
  | code ->
      Producer.Error.raise_error
        (Producer.Error.Source_unavailable (Printf.sprintf "http %d" code))

let meta s =
  let start = start_seqnum s in
  let start_walltime_ms =
    match s.walltime_ms > 0 && s.head_seqnum > 0 with
    | true -> s.walltime_ms - (s.head_seqnum - start) * (segment_duration_usec s / 1000)
    | false -> 0
  in
  { Producer.Meta.
    total_duration_usec = None;
    start_walltime_ms;
    is_live = s.is_live;
  }

let init_segment s =
  match s.init_raw with
  | Some raw -> raw
  | None ->
      let raw = fetch_latest s in
      s.init_raw <- Some raw;
      raw

let segments s =
  ensure_head s;
  let start = start_seqnum s in
  let count = s.head_seqnum - start + 1 in
  let dur = segment_duration_usec s in
  let segs =
    Array.init count ~f:(fun i ->
      { Producer.Segment_info.
        start_usec = (start + i) * dur;
        length_usec = dur;
        byte_length = 0;
      })
  in
  Producer.Segments.Streaming segs

let max_segment_id s = s.head_seqnum

let fetch_segment s ~id =
  let data = fetch_raw s ~sq:id in
  let dur = segment_duration_usec s in
  { Producer.Segment.
    start_usec = id * dur;
    length_usec = dur;
    data;
  }

let close _ = ()

type video_state = Producer.video state
type audio_state = Producer.audio state

let create_video ~clock ~client ~url ~headers ~is_live ~container ~codec ~dynamic_range ~rfc6381 ()
  : (module Producer.S with type kind = Producer.video) =
  (module struct
    type state = video_state
    type kind = Producer.video
    let witness = Producer.Kind.Video
    let init ~env:_ ~sw:_ ~target:_ =
      let shape : Producer.video Producer.Shape.t =
        Producer.Shape.Video { container; codec; dynamic_range; rfc6381 }
      in
      { client; clock; url; headers; container; is_live;
        head_seqnum = 0; head_time_millis = 0; walltime_ms = 0;
        last_fetch = 0.0; init_raw = None }, shape
    let meta = meta
    let init_segment = init_segment
    let segments = segments
    let max_segment_id = max_segment_id
    let fetch_segment = fetch_segment
    let close = close
  end)

let create_audio ~clock ~client ~url ~headers ~is_live ~container ~codec ~rfc6381 ()
  : (module Producer.S with type kind = Producer.audio) =
  (module struct
    type state = audio_state
    type kind = Producer.audio
    let witness = Producer.Kind.Audio
    let init ~env:_ ~sw:_ ~target:_ =
      let shape : Producer.audio Producer.Shape.t =
        Producer.Shape.Audio { container; codec; rfc6381 }
      in
      { client; clock; url; headers; container; is_live;
        head_seqnum = 0; head_time_millis = 0; walltime_ms = 0;
        last_fetch = 0.0; init_raw = None }, shape
    let meta = meta
    let init_segment = init_segment
    let segments = segments
    let max_segment_id = max_segment_id
    let fetch_segment = fetch_segment
    let close = close
  end)
