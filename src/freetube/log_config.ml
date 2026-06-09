open! Base

let overrides =
  [
    "application", Some Logs.Warning;
    "session.discovery_airplay", Some Logs.Warning;
    "session.discovery_dlna", Some Logs.Warning;
    "piaf.client", Some Logs.Warning;
    "piaf.http", Some Logs.Warning;
    "piaf.openssl", Some Logs.Warning;
    "piaf.server_impl", None;
  ]

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
    Fmt.kpf k Fmt.stderr
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
