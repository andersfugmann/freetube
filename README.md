# FreeTube

A self-hosted YouTube streaming and casting service written in OCaml.
FreeTube fetches video from YouTube and serves it to AirPlay and DLNA devices
on the local network — either as a direct cast URL or repackaged on the fly as
HLS or DASH.

## Features

- Stream YouTube videos to AirPlay 2 and DLNA/UPnP renderers
- On-the-fly HLS and DASH repackaging (no transcoding required)
- Codec-aware stream selection (HEVC, AV1, VP9, AAC, Opus)
- Device discovery via mDNS (AirPlay) and SSDP (DLNA)
- HTTP API for browsing and controlling playback
- Browser extension for casting directly from YouTube
- Per-device configuration and vendor-specific quirk handling

## Install

Debian packages are published with each
[release](https://github.com/andersfugmann/freetube/releases):

```sh
sudo dpkg -i freetube_<version>_amd64.deb
sudo systemctl enable --now freetube
```

The browser extension is available as a separate package:

```sh
sudo dpkg -i freetube-plugin_<version>_all.deb
```

## Build

Requires OCaml 5.3+ via opam.

```sh
# Create a local switch and install dependencies
opam switch create . ocaml-base-compiler.5.3.0
eval $(opam env)
opam install . --deps-only --with-test

# Build
make build

# Run tests
make test

# Run the server
make run
```
