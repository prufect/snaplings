#!/bin/bash
# Builds firmware/bridge and, with a port, flashes it to the XIAO ESP32S3 Sense.
#   firmware/build_bridge.sh http://SERVER_ADDRESS:8080 [/dev/cu.usbmodem...]
# The Wi-Fi details come from firmware/wifi.txt (see set_wifi.sh). They go into a temporary
# config.h that is deleted after the build and never printed.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
url="${1:?usage: build_bridge.sh SERVER_URL [PORT]}"
port="$2"
config="$here/bridge/config.h"
fqbn="esp32:esp32:XIAO_ESP32S3:USBMode=default,CDCOnBoot=cdc,PSRAM=opi,PartitionScheme=huge_app"

trap 'rm -f "$config"' EXIT
( umask 077
  python3 -I - "$here/wifi.txt" "$url" > "$config" <<'EOF'
import json, sys
name, password = open(sys.argv[1]).read().splitlines()[:2]
print(f"#define WIFI_NAME {json.dumps(name)}")
print(f"#define WIFI_PASSWORD {json.dumps(password)}")
print(f"#define SERVER_URL {json.dumps(sys.argv[2])}")
EOF
)
arduino-cli compile --fqbn "$fqbn" --output-dir "$here/bridge/build" "$here/bridge"
rm -f "$config"

if [ -n "$port" ]; then
  arduino-cli upload --fqbn "$fqbn" --input-dir "$here/bridge/build" --port "$port"
fi
