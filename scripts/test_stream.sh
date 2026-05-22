#!/bin/bash
STREAM_FILE=$1
VCODEC=$2
ACODEC=$3

if [ -z "${ACODEC}" ]; then
    echo "use $0 <stream file> vcodec acodec"
    exit 1
fi

echo "Testing $VCODEC, $ACODEC Stream"
STREAM="$(dune exec freetube_client -- stream --vcodecs $VCODEC --acodecs $ACODEC http://localhost:5544/${STREAM_FILE})" 2>/dev/null
if [ "$?" != "0" ]; then
    echo Could not contruct stream.
    exit 1
fi
echo Stream URL: ${STREAM}
scripts/verify_stream.sh "$STREAM"
if [ "$?" != "0" ]; then
    echo "Stream verification failed"
    exit 1
fi
