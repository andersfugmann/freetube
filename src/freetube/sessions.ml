open! Base

module Log = (val Util.Log_src.src_log ~doc:"Client session registry" Stdlib.__MODULE__)

type t = Session.t list ref

let init () : t = ref []

let add t session = t := session :: !t

let find t ~id =
  List.find !t ~f:(fun s -> String.equal (Session.id s) id)

let list t = !t

let remove t ~id =
  match find t ~id with
  | None -> ()
  | Some s ->
      t := List.filter !t ~f:(fun x ->
        not (String.equal (Session.id x) id));
      try Session.close s with _ -> ()
