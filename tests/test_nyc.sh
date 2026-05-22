#!/bin/bash
STREAM=http://10.0.0.8:5544/static/nyc/stream.json

cd $(dirname $0)
function test_stream() {
    VCODEC=$1
    ACODEC=$2
    echo "Testing $VCODEC, $ACODEC Stream"
    STREAM="$(dune exec ../src/bin/stream.exe -- --video-codecs $VCODEC --audio-codecs $ACODEC ${STREAM})" 2>/dev/null
    if [ "$?" != "0" ]; then
        echo Could not contruct stream.
        exit 1
    fi
    echo Stream URL: ${STREAM}
    ../scripts/verify_stream.sh "$STREAM"
    if [ "$?" != "0" ]; then
        echo "Stream verification failed"
        exit 1
    fi
}

test_stream vp9 aac
