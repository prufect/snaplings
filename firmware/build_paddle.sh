#!/bin/bash
# Builds firmware/paddle with Zephyr in ~/zephyrproject and, with "flash", flashes it to the
# XIAO nRF54L15 Sense over its USB debug probe.
#   firmware/build_paddle.sh [flash]
set -e
here="$(cd "$(dirname "$0")" && pwd)"
source "$HOME/zephyrproject/.venv/bin/activate"
export ZEPHYR_BASE="$HOME/zephyrproject/zephyr"
cd "$HOME/zephyrproject"
west build -p auto -b xiao_nrf54l15/nrf54l15/cpuapp -d "$here/paddle/build" "$here/paddle"

if [ "$1" = "flash" ]; then
  # auto_unlock stays off because otherwise pyOCD erases a locked chip without asking.
  uvx pyocd load -t nrf54l -O auto_unlock=false --format hex "$here/paddle/build/zephyr/zephyr.hex"
  uvx pyocd reset -t nrf54l -O auto_unlock=false
fi
