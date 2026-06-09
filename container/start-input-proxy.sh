#!/bin/sh
set -eu

if [ "${WEBRTC_ENABLED:-0}" != "1" ]; then
  printf '[input] disabled (WEBRTC_ENABLED=%s)\n' "${WEBRTC_ENABLED:-0}" >&2
  exit 0
fi

export DISPLAY="${DISPLAY:-:1}"
export WEBRTC_INPUT_PORT="${WEBRTC_INPUT_PORT:-5731}"

exec /usr/bin/python3 /opt/ra2/input-proxy.py
