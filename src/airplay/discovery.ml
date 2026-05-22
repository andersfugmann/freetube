open! Base

let scan ~net ~clock ?(timeout = 5.0) () =
  Mdns.browse ~net ~clock ~timeout
  |> List.map ~f:(fun (d : Mdns.device) ->
    Airplay.Client.create ~name:d.name ?fn:d.fn ~address:d.address ~port:d.port
      ~pairing_id:d.pi ?public_key:d.pk ?features:d.features ?flags:d.flags
      ?model:d.model ~txt:d.txt ())
