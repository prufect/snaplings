#!/bin/bash
# Saves the Wi-Fi details the XIAO should use to firmware/wifi.txt, readable only by you.
# The password is hidden as you type and is never printed.
file="$(dirname "$0")/wifi.txt"
read -r -p "Wi-Fi name: " name
read -r -s -p "Wi-Fi password: " password
echo
( umask 077; printf '%s\n%s\n' "$name" "$password" > "$file" )
echo "Saved. You can close this tab."
