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
    export ULTRA_VIDEO_CODEC="${ULTRA_VIDEO_CODEC:-H264}"
    export ULTRA_VIDEO_FPS="${ULTRA_VIDEO_FPS:-24}"
    export ULTRA_VIDEO_BITRATE="${ULTRA_VIDEO_BITRATE:-900000}"
    ;;
  *)
    export ULTRA_VIDEO_CODEC="${ULTRA_VIDEO_CODEC:-H264}"
    export ULTRA_VIDEO_FPS="${ULTRA_VIDEO_FPS:-24}"
    export ULTRA_VIDEO_BITRATE="${ULTRA_VIDEO_BITRATE:-1000000}"
    ;;
esac

# Stream size follows display.env (updated per game via switch-game-display.sh).
# Do not export ULTRA_VIDEO_WIDTH/HEIGHT here — the gateway reads display.env
# on each sync so a game switch (e.g. StarCraft 640x480) is not pinned to boot size.
DISPLAY_ENV="${ULTRA_DISPLAY_ENV:-/home/commander/.ra2/display.env}"
if [ -f "$DISPLAY_ENV" ]; then
  # shellcheck disable=SC1090
  . "$DISPLAY_ENV"
fi
export RESOLUTION="${RESOLUTION:-1024x768}"

export ULTRA_VIDEO_KEYFRAME_SECONDS="${ULTRA_VIDEO_KEYFRAME_SECONDS:-1}"
export ULTRA_VIDEO_REQUIRE_HW="${ULTRA_VIDEO_REQUIRE_HW:-1}"
export ULTRA_AUDIO_CODEC="${ULTRA_AUDIO_CODEC:-opus}"
export ULTRA_AUDIO_BITRATE="${ULTRA_AUDIO_BITRATE:-64000}"
export ULTRA_AUDIO_FRAME_MS="${ULTRA_AUDIO_FRAME_MS:-20}"
if [ "${ULTRA_AUDIO_CODEC:-opus}" = "opus" ]; then
  export ULTRA_AUDIO_RATE="${ULTRA_AUDIO_RATE:-48000}"
  export ULTRA_AUDIO_TRANSPORT_RATE="${ULTRA_AUDIO_TRANSPORT_RATE:-48000}"
else
  export ULTRA_AUDIO_RATE="${ULTRA_AUDIO_RATE:-44100}"
  export ULTRA_AUDIO_TRANSPORT_RATE="${ULTRA_AUDIO_TRANSPORT_RATE:-$ULTRA_AUDIO_RATE}"
fi
export ULTRA_VIDEO_DIAGNOSTICS="${ULTRA_VIDEO_DIAGNOSTICS:-1}"
export ULTRA_STREAM_CPUSET="${ULTRA_STREAM_CPUSET:-}"
export ULTRA_VIDEO_GPU_SCALE="${ULTRA_VIDEO_GPU_SCALE:-1}"
if [ -n "${ULTRA_GST_DEBUG:-}" ]; then
  export GST_DEBUG="$ULTRA_GST_DEBUG"
fi

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

HELPER_SRC="/opt/ra2/stream-helper.c"
ULTRA_STREAM_HELPER="${ULTRA_STREAM_HELPER:-/opt/ra2/stream-helper}"
# Synology tmpfs mounts are noexec; compile/run the helper on the container layer.
case "$ULTRA_STREAM_HELPER" in
  /tmp/*|/opt/ra2/ram/*)
    ULTRA_STREAM_HELPER="/opt/ra2/stream-helper"
    ;;
esac

if [ -f "$HELPER_SRC" ] && command -v gcc >/dev/null 2>&1 && command -v pkg-config >/dev/null 2>&1; then
  if [ ! -x "$ULTRA_STREAM_HELPER" ] || [ "$HELPER_SRC" -nt "$ULTRA_STREAM_HELPER" ]; then
    printf '[ultra-gateway] rebuilding stream helper from %s\n' "$HELPER_SRC" >&2
    if gcc "$HELPER_SRC" -o "$ULTRA_STREAM_HELPER" \
      $(pkg-config --cflags --libs gstreamer-1.0 gstreamer-app-1.0) 2>/tmp/stream-helper-build.log; then
      chmod +x "$ULTRA_STREAM_HELPER" 2>/dev/null || true
    else
      tail -20 /tmp/stream-helper-build.log >&2 || true
      printf '[ultra-gateway] stream helper rebuild failed; using existing binary\n' >&2
    fi
  fi
fi
export ULTRA_STREAM_HELPER

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
  "${RESOLUTION%x*}" \
  "${RESOLUTION#*x}" \
  "$ULTRA_VIDEO_FPS" \
  "$ULTRA_VIDEO_BITRATE" \
  "$ULTRA_VIDEO_REQUIRE_HW" \
  "$ULTRA_GATEWAY_TLS" \
  "$DIAGNOSTIC_DIR" >&2

if [ "$ULTRA_VIDEO_DIAGNOSTICS" = "1" ] && [ -f /opt/ra2/log-video-diagnostics.sh ]; then
  ULTRA_VIDEO_DIAGNOSTICS_LOG="${ULTRA_VIDEO_DIAGNOSTICS_LOG:-${DIAGNOSTIC_DIR}/video-diagnostics.log}" \
    /bin/sh /opt/ra2/log-video-diagnostics.sh || true
fi

exec /usr/bin/python3 /opt/ra2/ra2-stream-gateway.py >>"$GATEWAY_LOG" 2>&1
