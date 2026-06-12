open! Base

type status =
  | Ok
  | No_content

type content_type =
  | Explicit of string
  | Infer_from_filename of string
  | No_content_type

type accept_ranges =
  | Allow_ranges
  | No_ranges

type t = {
  status : status;
  headers : (string * string) list;
  body : string;
  content_type : content_type;
  accept_ranges : accept_ranges;
}

let make ?(headers = []) ?(content_type = No_content_type)
    ?(accept_ranges = No_ranges) ~status ~body () =
  { status; headers; body; content_type; accept_ranges }

let ok ?headers ?content_type ?accept_ranges body =
  make ?headers ?content_type ?accept_ranges ~status:Ok ~body ()

let no_content ?headers () =
  make ?headers ~status:No_content ~body:"" ()

