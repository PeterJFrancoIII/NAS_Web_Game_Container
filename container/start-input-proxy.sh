#!/bin/sh
set -eu

if [ "${WEBRTC_ENABLED:-0}" != "1" ]; then
  printf '[input] disabled (WEBRTC_ENABLED=%s)\n' "${WEBRTC_ENABLED:-0}" >&2
  exit 0
fi

export DISPLAY="${DISPLAY:-:1}"
export WEBRTC_INPUT_PORT="${WEBRTC_INPUT_PORT:-5731}"
export WEBRTC_INPUT_BACKEND="${WEBRTC_INPUT_BACKEND:-xdotool}"
export UINPUT_DEVICE="${UINPUT_DEVICE:-/dev/uinput}"
TLS_CERT="${TLS_CERT:-/opt/ra2/tls/cert.pem}"
TLS_KEY="${TLS_KEY:-/opt/ra2/tls/key.pem}"
case "${WEBRTC_INPUT_TLS:-}" in
  1|true|yes)
    export WEBRTC_INPUT_TLS=1
    ;;
  0|false|no)
    export WEBRTC_INPUT_TLS=0
    ;;
  "")
    if [ -f "$TLS_CERT" ] && [ -f "$TLS_KEY" ]; then
      export WEBRTC_INPUT_TLS=1
    else
      export WEBRTC_INPUT_TLS=0
    fi
    ;;
esac

exec /usr/bin/python3 /opt/ra2/input-proxy.py
