#!/bin/bash
set -euo pipefail

if [ "$#" -lt 3 ]; then
    echo "Use: $0 <youtube url> <dest dir> <base-url> [stream id]..." >&2
    exit 1
fi

URL="$1"; shift
DIR="$1"; shift
BASE_URL="${1%/}"; shift
IDS=("$@")

mkdir -p "$DIR"

yt-dlp -J "$URL" > "$DIR/.stream.full.json"

if [ "${#IDS[@]}" -eq 0 ]; then
    if ! command -v fzf >/dev/null; then
        echo "fzf not installed; pass stream ids on the command line" >&2
        exit 1
    fi
    mapfile -t IDS < <(
        yt-dlp -q --no-warnings -F "$URL" \
        | grep -v '^\[' \
        | fzf --multi --header-lines=2 \
              --prompt='streams> ' --height=80% --reverse \
        | awk '{print $1}'
    )
    if [ "${#IDS[@]}" -eq 0 ]; then
        echo "No streams selected" >&2
        exit 1
    fi
fi

FORMAT_SPEC=$(IFS=,; echo "${IDS[*]}")

yt-dlp \
    -f "$FORMAT_SPEC" \
    --fixup never \
    --no-overwrites \
    --cookies-from-browser edge \
    --js-runtimes deno \
    --remote-components ejs:github \
    -o "$DIR/%(format_id)s.%(ext)s" \
    "$URL"

ID_JSON=$(printf '%s\n' "${IDS[@]}" | jq -R . | jq -s .)

jq --arg base "$BASE_URL" --argjson ids "$ID_JSON" '
    .formats |= (
        map(select(.format_id | IN($ids[])))
        | map(
            . as $f
            | .url = ($base + "/" + $f.format_id + "." + $f.ext)
            | del(.fragments, .fragment_base_url, .manifest_url, .http_headers)
          )
    )
    | del(.requested_formats, .formats_table, .urls)
' "$DIR/.stream.full.json" > "$DIR/streams.json"

rm -f "$DIR/.stream.full.json"

echo "Wrote $DIR/stream.json with ${#IDS[@]} stream(s)"
