open! Base

type t = {
  domain : string;
  include_subdomains : bool [@default true];
  path : string [@default "/"];
  secure : bool [@default true];
  expires : int [@default 0];
  name : string;
  value : string;
} [@@deriving yojson { strict = false }]

let to_line t =
  Printf.sprintf "%s\t%s\t%s\t%s\t%d\t%s\t%s"
    t.domain
    (if t.include_subdomains then "TRUE" else "FALSE")
    t.path
    (if t.secure then "TRUE" else "FALSE")
    t.expires
    t.name
    t.value

let to_netscape cookies =
  let lines = List.map cookies ~f:to_line in
  String.concat ~sep:"\n" ("# Netscape HTTP Cookie File" :: lines) ^ "\n"

let of_yojson_list = function
  | `List items ->
      List.filter_map items ~f:(fun item ->
          match of_yojson item with
          | Ok c -> Some c
          | Error _ -> None)
  | json ->
      match of_yojson json with
      | Ok c -> [ c ]
      | Error _ -> []
