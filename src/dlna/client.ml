open! Base

(* Opaque description of a discovered DLNA MediaRenderer. Built by [Discovery]
   (from the device-description XML) or via [create]; freetube persists it
   through [to_yojson]/[of_yojson]. *)
type t = {
  friendly_name : string;
  udn : string;
  control_url : string;
  device_type : string;
  manufacturer : string;
  model_name : string;
  icon_url : string option;
  location_base : string;
  services : string list;
  address : string;
} [@@deriving yojson { strict = false }]

let create ~friendly_name ~udn ~control_url ~device_type ~manufacturer
    ~model_name ?icon_url ~location_base ?(services = []) ~address () =
  match String.is_empty udn, String.is_empty control_url with
  | true, _ -> failwith "Dlna.Client.create: empty udn"
  | _, true -> failwith "Dlna.Client.create: empty control_url"
  | false, false ->
      { friendly_name; udn; control_url; device_type; manufacturer;
        model_name; icon_url; location_base; services; address }

let friendly_name t = t.friendly_name
let udn t = t.udn
let control_url t = t.control_url
let device_type t = t.device_type
let manufacturer t = t.manufacturer
let model_name t = t.model_name
let icon_url t = t.icon_url
let location_base t = t.location_base
let services t = t.services
let address t = t.address
