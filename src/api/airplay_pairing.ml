open! Base

(* Wire envelopes for the AirPlay pairing HTTP endpoints. Shared by the
   freetube server and the airplay_pair CLI; kept out of the airplay
   protocol library, which has no HTTP concern. *)

type pair_start_request = {
  device_id : string;
} [@@deriving yojson]

type pair_start_response = {
  session_id : string;
} [@@deriving yojson]

type pair_finish_request = {
  session_id : string;
  pin : string;
} [@@deriving yojson]

type pair_finish_response = {
  pairing_id : string;
} [@@deriving yojson]
