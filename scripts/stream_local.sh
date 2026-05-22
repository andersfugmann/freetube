#!/bin/bash

YT_ID=${1//*=}

if [ -z "$YT_ID" ]; then
    echo "Use: $0 <youtube id>"
fi
cd $(dirname $0)
STREAM=$(dune exec freetube_client -- stream ${YT_ID})
echo ${STREAM}
mpv ${STREAM}
