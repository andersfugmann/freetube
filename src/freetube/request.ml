open! Base

type method_ =
  [ `GET
  | `POST
  | `PUT
  | `DELETE
  | `HEAD
  | `OPTIONS
  | `Other of string
  ]

type byte_range =
  | Suffix of int
  | From of int
  | From_to of int * int

type range =
  | No_range
  | Invalid_range
  | Byte_range of byte_range

type host =
  | No_host
  | Host of string

type client =
  | Unknown_client
  | Peer of Eio.Net.Sockaddr.stream

type t = {
  method_ : method_;
  path : string;
  headers : (string * string) list;
  body : string;
  range : range;
  host : host;
  client : client;
}

