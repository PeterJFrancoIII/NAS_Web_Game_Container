#!/bin/sh
set -eu

if [ "${WEBRTC_ENABLED:-0}" != "1" ]; then
  printf '[webrtc] disabled (WEBRTC_ENABLED=%s)\n' "${WEBRTC_ENABLED:-0}" >&2
  exit 0
fi

export DISPLAY="${DISPLAY:-:1}"
export WEBRTC_SIGNAL_PORT="${WEBRTC_SIGNAL_PORT:-6090}"
export WEBRTC_UDP_PORT_MIN="${WEBRTC_UDP_PORT_MIN:-62001}"
export WEBRTC_UDP_PORT_MAX="${WEBRTC_UDP_PORT_MAX:-62020}"
export STUN_URL="${STUN_URL:-stun:stun.l.google.com:19302}"
export WEBRTC_VIDEO_FPS="${WEBRTC_VIDEO_FPS:-20}"
export WEBRTC_VIDEO_BITRATE="${WEBRTC_VIDEO_BITRATE:-800000}"
export PULSE_TCP_PORT="${PULSE_TCP_PORT:-4711}"

exec /usr/bin/python3 /opt/ra2/webrtc-media.py
