#!/bin/bash
set -euo pipefail

URL="$1"

# Temporary file for JSON output
TMP=$(mktemp)

# Run ffprobe and capture JSON
if ! ffprobe -hide_banner -v error \
    -print_format json \
    -show_packets \
    -show_streams \
    -show_error \
    "$URL" > "$TMP"; then
    echo "ERROR: ffprobe failed to read stream"
    exit 1
fi

# Check for ffprobe-level errors
if jq -e '.error' "$TMP" >/dev/null; then
    echo "ERROR: ffprobe reported an error"
    jq '.error' "$TMP"
    exit 1
fi

# Ensure we have at least one audio or video stream
STREAM_COUNT=$(jq '.streams | length' "$TMP")
if [ "$STREAM_COUNT" -eq 0 ]; then
    echo "ERROR: No audio/video streams found"
    exit 1
fi

# Check for missing codec info
if jq -e '.streams[] | select(.codec_type == null or .codec_name == null)' "$TMP" >/dev/null; then
    echo "ERROR: Missing codec information in stream"
    exit 1
fi

# Detect PTS/DTS regressions (monotonicity check)
if jq -e '
    .packets
    | group_by(.stream_index)
    | .[]
    | reduce .[] as $p (
        {last_pts: null, bad: false};
        if .last_pts != null and ($p.pts != null and $p.pts < .last_pts)
        then {last_pts: $p.pts, bad: true}
        else {last_pts: $p.pts, bad: .bad}
        end
    )
    | select(.bad == true)
' "$TMP" >/dev/null; then
    echo "ERROR: PTS regression detected"
    exit 1
fi

# Detect large timestamp gaps (> 1 second)
if jq -e '
    .packets
    | group_by(.stream_index)
    | .[]
    | reduce .[] as $p (
        {last_pts: null, bad: false};
        if .last_pts != null and ($p.pts != null and ($p.pts - .last_pts) > 90000)
        then {last_pts: $p.pts, bad: true}
        else {last_pts: $p.pts, bad: .bad}
        end
    )
    | select(.bad == true)
' "$TMP" >/dev/null; then
    echo "ERROR: Large PTS gap detected"
    exit 1
fi

echo "ffmpeg -xerror -v warning -i $URL -f null -"
if ! ffmpeg -xerror -i "$URL" -f null -; then
    echo "Decoding failed"
    exit 1
fi


echo "OK: Stream is valid"
exit 0
