open! Base

let overrides =
  [
    "application", Some Logs.Warning;
    "session.discovery_airplay", Some Logs.Warning;
    "session.discovery_dlna", Some Logs.Warning;
    "piaf.client", Some Logs.Warning;
    "piaf.connection", Some Logs.Warning;
    "piaf.http", Some Logs.Warning;
    "piaf.openssl", Some Logs.Warning;
    "piaf.server_impl", Some Logs.Warning;
    "airplay_protocol.airplay_http", Some Logs.Warning
  ]

let should_drop src line =
  String.equal (Logs.Src.name src) "piaf.server_impl"
  && String.is_substring line ~substring:"cannot write to closed writer"

let reporter () =
  let report src level ~over k msgf =
    let k _ = over (); k () in
    let time = Unix.gettimeofday () in
    let tm = Unix.localtime time in
    let ms = Float.to_int ((time -. Float.round_down time) *. 1000.) in
    let ts =
      Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.%03d"
        (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
        tm.tm_hour tm.tm_min tm.tm_sec ms
    in
    let level_str =
      match level with
      | Logs.App -> "APP"
      | Error -> "ERROR"
      | Warning -> "WARN"
      | Info -> "INFO"
      | Debug -> "DEBUG"
    in
    msgf @@ fun ?header:_ ?tags:_ fmt ->
    let buf = Buffer.create 256 in
    let ppf = Stdlib.Format.formatter_of_buffer buf in
    let finish _ =
      Stdlib.Format.pp_print_flush ppf ();
      let line = Buffer.contents buf in
      (match should_drop src line with
       | true -> ()
       | false -> Stdlib.output_string Stdlib.stderr line; Stdlib.flush Stdlib.stderr);
      k ()
    in
    Fmt.kpf finish ppf
      (Stdlib.( ^^ ) (Stdlib.( ^^ ) "%s [%5s] [%s] @[" fmt) "@]@.")
      ts level_str (Logs.Src.name src)
  in
  { Logs.report }

let init () =
  Logs.set_reporter (reporter ());
  Logs.set_level (Some Logs.Info);
  List.iter (Logs.Src.list ()) ~f:(fun src ->
      List.find overrides ~f:(fun (name, _) -> String.equal name (Logs.Src.name src))
      |> Option.iter ~f:(fun (_, level) -> Logs.Src.set_level src level)
    )
