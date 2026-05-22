open! Base

type t = {
  name : string;
  fn : string option; [@default None]
  address : string;
  port : int;
  pairing_id : string;
  public_key : string option; [@default None]
  features : string option; [@default None]
  flags : string option; [@default None]
  model : string option; [@default None]
  txt : (string * string) list; [@default []]
} [@@deriving yojson { strict = false }]

let create ~name ?fn ~address ~port ~pairing_id ?public_key ?features ?flags
      ?model ?(txt = []) () =
  match String.is_empty pairing_id, port > 0 with
  | true, _ -> failwith "Airplay.Client.create: empty pairing_id"
  | _, false -> Printf.failwithf "Airplay.Client.create: invalid port %d" port ()
  | false, true ->
      { name; fn; address; port; pairing_id; public_key; features; flags;
        model; txt }

let name t = t.name
let friendly_name t = Option.value t.fn ~default:t.name
let address t = t.address
let port t = t.port
let pairing_id t = t.pairing_id
let public_key t = t.public_key
let features t = t.features
let flags t = t.flags
let model t = t.model
let txt t = t.txt
