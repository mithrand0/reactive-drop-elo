#!/bin/bash
set -e

msg="$*"
mkdir -p /tmp/artifacts
bin/buildscript.sh --push --testing

CONTAINER_ID=$(docker ps -q 2>/dev/null)
if [[ "$CONTAINER_ID" != "" ]]; then
    docker stop $CONTAINER_ID
fi

docker run -d mithrand0/reactive-drop-elo:testing
CONTAINER_ID=$(docker ps -lq)
docker cp $CONTAINER_ID:/rd_elo.smx /tmp/artifacts/
docker stop $CONTAINER_ID

cp -f README.md /tmp/artifacts
chmod -R uog+r /tmp/artifacts
