#!/bin/bash
# Plays the game by script on LÖVE 11.4 (the R36S's version) in a Linux container, with no screen or sound.
#   game/tests/run_game_test.sh PACKET PHOTO SPAWN OUTPUT_DIR
# PACKET is a creature packet saved from the server, PHOTO is any camera JPEG, and SPAWN
# is an /audio reply that asks for a creature. Set REDRAW to an /audio reply that redraws one.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
docker run --rm --platform linux/arm64 \
  -v "$root/snaplings:/game:ro" -v "$root/tests:/tests:ro" \
  ${REDRAW:+-v "$(realpath "$REDRAW"):/redraw:ro" -e SNAPLINGS_REDRAW=/redraw} \
  -v "$(realpath "$1"):/packet:ro" -v "$(realpath "$2"):/photo:ro" -v "$(realpath "$3"):/spawn:ro" -v "$(realpath "$4"):/out" \
  debian:bookworm-slim sh -c '
    apt-get update -qq >/dev/null && apt-get install -y -qq love xvfb libgl1-mesa-dri >/dev/null 2>&1
    love --version
    mkdir -p /tmp/save
    export SNAPLINGS_DEV=/tests/dev_script.lua SNAPLINGS_OUT=/out SNAPLINGS_PACKET=/packet SNAPLINGS_PHOTO=/photo SNAPLINGS_SPAWN=/spawn
    export GAMEDIR=/tmp/save SNAPLINGS_SERIAL=/tmp/link SDL_AUDIODRIVER=dummy LIBGL_ALWAYS_SOFTWARE=1
    # A pipe held open stays connected, as the real link does.
    mkfifo /tmp/link
    sleep 100000 <> /tmp/link &
    SNAPLINGS_STAGE=1 xvfb-run -a -s "-screen 0 640x480x24" love /game
    echo "--- saved after first run"; cat /tmp/save/team.txt; ls /tmp/save/creatures | wc -l
    SNAPLINGS_STAGE=2 xvfb-run -a -s "-screen 0 640x480x24" love /game
  '
