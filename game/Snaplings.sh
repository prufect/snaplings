#!/bin/bash
# ArkOS Ports launcher for Snaplings.
# Copy this file to /roms/ports/ and the game folder to /roms/ports/snaplings/.

export GAMEDIR=/roms/ports/snaplings

# /dev/ttyACM0 is root:dialout and games run as ark. It's recreated with those
# permissions whenever the XIAO reconnects, so keep opening it up while the game runs.
(
  while true; do
    if [ -e /dev/ttyACM0 ] && [ "$(stat -c %a /dev/ttyACM0)" != "666" ]; then
      sudo chmod 666 /dev/ttyACM0
      stty -F /dev/ttyACM0 raw -echo 115200
    fi
    sleep 0.5
  done
) &
WATCHER=$!

export LD_LIBRARY_PATH="/opt/love2d/lib:$LD_LIBRARY_PATH"
export SDL_GAMECONTROLLERCONFIG_FILE="/opt/love2d/gamecontrollerdb.txt"
cd /opt/love2d
./love "$GAMEDIR" > "$GAMEDIR/love-output.log" 2>&1

kill $WATCHER
