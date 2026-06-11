#!/bin/sh
set -eu

if [ "${ULTRA_STREAM_ENABLED:-1}" != "1" ]; then
  printf '[ultra-gateway] disabled (ULTRA_STREAM_ENABLED=%s)\n' "${ULTRA_STREAM_ENABLED:-0}" >&2
  exit 0
fi

export DISPLAY="${DISPLAY:-:1}"
export ULTRA_GATEWAY_PORT="${ULTRA_GATEWAY_PORT:-6080}"
export ULTRA_STREAM_HELPER="${ULTRA_STREAM_HELPER:-/opt/ra2/stream-helper}"
export LIBVA_DRIVER_NAME="${LIBVA_DRIVER_NAME:-i965}"
export GST_VAAPI_ALL_DRIVERS="${GST_VAAPI_ALL_DRIVERS:-1}"
export GST_VA_ALL_DRIVERS="${GST_VA_ALL_DRIVERS:-1}"
export PULSE_TCP_PORT="${PULSE_TCP_PORT:-4711}"

RA2_MEMORY_PROFILE="${RA2_MEMORY_PROFILE:-two-player-low}"
case "$RA2_MEMORY_PROFILE" in
  two-player-low)
    export RESOLUTION="${RESOLUTION:-1024x768}"
    export ULTRA_VIDEO_CODEC="${ULTRA_VIDEO_CODEC:-H264}"
    export ULTRA_VIDEO_WIDTH="${ULTRA_VIDEO_WIDTH:-1024}"
    export ULTRA_VIDEO_HEIGHT="${ULTRA_VIDEO_HEIGHT:-768}"
    export ULTRA_VIDEO_FPS="${ULTRA_VIDEO_FPS:-24}"
    export ULTRA_VIDEO_BITRATE="${ULTRA_VIDEO_BITRATE:-900000}"
    ;;
  *)
    export ULTRA_VIDEO_CODEC="${ULTRA_VIDEO_CODEC:-H264}"
    export ULTRA_VIDEO_WIDTH="${ULTRA_VIDEO_WIDTH:-1024}"
    export ULTRA_VIDEO_HEIGHT="${ULTRA_VIDEO_HEIGHT:-768}"
    export ULTRA_VIDEO_FPS="${ULTRA_VIDEO_FPS:-24}"
    export ULTRA_VIDEO_BITRATE="${ULTRA_VIDEO_BITRATE:-1000000}"
    ;;
esac

export ULTRA_VIDEO_KEYFRAME_SECONDS="${ULTRA_VIDEO_KEYFRAME_SECONDS:-1}"
export ULTRA_VIDEO_REQUIRE_HW="${ULTRA_VIDEO_REQUIRE_HW:-1}"
export ULTRA_AUDIO_CODEC="${ULTRA_AUDIO_CODEC:-opus}"
export ULTRA_AUDIO_BITRATE="${ULTRA_AUDIO_BITRATE:-96000}"
export ULTRA_AUDIO_FRAME_MS="${ULTRA_AUDIO_FRAME_MS:-10}"
export ULTRA_AUDIO_RATE="${ULTRA_AUDIO_RATE:-44100}"
export ULTRA_AUDIO_TRANSPORT_RATE="${ULTRA_AUDIO_TRANSPORT_RATE:-48000}"

TLS_CERT="${TLS_CERT:-/opt/ra2/tls/cert.pem}"
TLS_KEY="${TLS_KEY:-/opt/ra2/tls/key.pem}"
case "${ULTRA_GATEWAY_TLS:-}" in
  1|true|yes)
    export ULTRA_GATEWAY_TLS=1
    ;;
  0|false|no)
    export ULTRA_GATEWAY_TLS=0
    ;;
  "")
    if [ -f "$TLS_CERT" ] && [ -f "$TLS_KEY" ]; then
      export ULTRA_GATEWAY_TLS=1
    else
      export ULTRA_GATEWAY_TLS=0
    fi
    ;;
esac

if [ ! -x "$ULTRA_STREAM_HELPER" ]; then
  printf '[ultra-gateway] missing stream helper at %s\n' "$ULTRA_STREAM_HELPER" >&2
  exit 1
fi

REQUESTED_LOG_ROOT="${ULTRA_GAME_LOG_ROOT:-/home/commander/ra2-logs-root}"
DEFAULT_LOG_ROOT="${WINEPREFIX:-/home/commander/.wine}/ra2-crash-logs"
if grep -qs " ${REQUESTED_LOG_ROOT} " /proc/mounts 2>/dev/null; then
  LOG_ROOT="$REQUESTED_LOG_ROOT"
else
  LOG_ROOT="$DEFAULT_LOG_ROOT"
fi
DIAGNOSTIC_DIR="${ULTRA_GAME_DIAGNOSTIC_DIR:-${LOG_ROOT}/player${PLAYER_ID:-unknown}}"
GATEWAY_LOG="${ULTRA_GATEWAY_LOG:-${DIAGNOSTIC_DIR}/gateway.log}"
mkdir -p "$DIAGNOSTIC_DIR" 2>/dev/null || true

printf '[ultra-gateway] codec=%s %sx%s@%sfps bitrate=%s require_hw=%s tls=%s logs=%s\n' \
  "$ULTRA_VIDEO_CODEC" \
  "$ULTRA_VIDEO_WIDTH" \
  "$ULTRA_VIDEO_HEIGHT" \
  "$ULTRA_VIDEO_FPS" \
  "$ULTRA_VIDEO_BITRATE" \
  "$ULTRA_VIDEO_REQUIRE_HW" \
  "$ULTRA_GATEWAY_TLS" \
  "$DIAGNOSTIC_DIR" >&2

exec /usr/bin/python3 /opt/ra2/ra2-stream-gateway.py >>"$GATEWAY_LOG" 2>&1
