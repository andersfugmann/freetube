(lang dune 3.0)

(name freetube)

(generate_opam_files true)

(source
 (github andersfugmann/freetube))

(authors "Anders Fugmann")

(maintainers "Anders Fugmann")

(license ISC)

(package
 (name freetube)
 (synopsis "FreeTube - YouTube streaming service")
 (depends
  (ocaml
   (>= 5.1))
  (dune
   (>= 3.0))
  eio
  eio_main
  base
  piaf
  routes
  ppx_deriving_yojson
  ppx_inline_test
  ppx_expect
  ppx_compare
  ppx_jane
  logs
  fmt
  yojson
  lwt
  obus
  stdio
  ezxmlm
  uri
  ipaddr
  dns
  magic-mime
  mirage-crypto
  mirage-crypto-ec
  mirage-crypto-pk
  mirage-crypto-rng
  mirage-crypto-rng-eio
  digestif
  ohex
  memfd
  xdg
  zarith
  js_of_ocaml
  js_of_ocaml-ppx
  cmdliner))
