#!/usr/bin/env bash
# Run Apple's mediastreamvalidator against a freshly-started session.
# Exits gracefully (success) if the tool is not installed — Apple
# distributes it macOS-only, so this is a best-effort hook for
# developers on a Mac.
#
# Usage: validate_hls.sh <streams.json> [<vcodec> [<acodec>]]

set -euo pipefail

if ! command -v mediastreamvalidator >/dev/null 2>&1; then
  echo "mediastreamvalidator not installed — skipping (this is fine on Linux)."
  exit 0
fi

streams_json="${1:?usage: validate_hls.sh <streams.json> [vcodec] [acodec]}"
vcodec="${2:-hevc}"
acodec="${3:-aac}"

host="${FREETUBE_HOST:-127.0.0.1}"
port="${FREETUBE_PORT:-5544}"
base="http://${host}:${port}"

session_id=$(curl -sf -X POST "${base}/sessions" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg s "$streams_json" --arg v "$vcodec" --arg a "$acodec" \
        '{streams_file: $s, video_codecs: [$v], audio_codecs: [$a]}')" \
  | jq -r '.id')

trap 'curl -sf -X DELETE "${base}/sessions/${session_id}" >/dev/null || true' EXIT

master="${base}/sessions/${session_id}/master.m3u8"
echo "Validating ${master}"
mediastreamvalidator "${master}"
