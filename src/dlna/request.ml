open! Base

type play = {
  friendly_name : string;
  filename : string;
} [@@deriving yojson]

type device = {
  friendly_name : string;
  udn : string;
  control_url : string;
  device_type : string;
  manufacturer : string;
  model_name : string;
  icon_url : string option;
  location_base : string;
  address : string;
  services : string list;
} [@@deriving yojson]

type devices = {
  devices : device list;
} [@@deriving yojson]
