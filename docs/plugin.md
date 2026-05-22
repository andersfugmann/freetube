# FreeTube Cast browser extension

A Chrome / Edge (MV3) extension that adds a cast button to the YouTube
player. Pressing it shows the list of FreeTube devices and streams the
current video to the selected one. The extension forwards the user's
`youtube.com` cookies to the FreeTube server so `yt-dlp` can resolve
age- and login-gated streams.

## Build

The extension is written in OCaml and compiled to JavaScript with
`js_of_ocaml`. Source lives in `src/plugin/`; bundled artifacts land
in `plugin/dist/`.

```
make plugin
```

This runs `dune build --profile=release src/plugin/` (with
`--opt 3 --target-env browser`, so each entry-point is fully tree-shaken),
then copies the three JS bundles, `manifest.json`, `popup.html`, and
any `plugin/icons/*.png` into `plugin/dist/`.

## Load (Chrome)

1. Open `chrome://extensions`.
2. Enable **Developer mode** (top right).
3. Click **Load unpacked** and select `plugin/dist/`.

## Load (Edge)

1. Open `edge://extensions`.
2. Enable **Developer mode** (left sidebar).
3. Click **Load unpacked** and select `plugin/dist/`.

## Configure

Click the extension's toolbar icon to open the popup:

- **Server URL** — the address of your FreeTube server (default
  `http://freetube.local:5544`). Saved in `chrome.storage.local`.
- **Test connection** — issues `GET /devices` and shows the count.
- **Devices** — each discovered device exposes a config form for
  vendor, supported video/audio codecs, and transcode toggle.
  Saving issues `PUT /devices/:id/config` against the server.

## Use

Open any `youtube.com/watch?v=…` page, click the cast button in the
player's right controls, pick a device. The extension reads the
current `v=` id and posts:

```
POST /sessions
{
  "source":  ["youtube_id", "<id>"],
  "sink":    "<device id>",
  "cookies": [ ...all .youtube.com cookies, netscape jar format... ]
}
```

The server uses the cookies for the `yt-dlp --cookies` netscape jar
when fetching the video.

## Notes

- The plugin requires CORS on the server. The server enables permissive
  CORS (`Access-Control-Allow-Origin: <echo>`) for all routes by default
  — see `src/http_server/cors.ml`.
- Cookie capture happens in the background service worker so HttpOnly
  cookies (incl. SAPISID) are included.
- All wire types are shared with the OCaml server via the
  `src/api/` library, so request/response shapes can never drift.
