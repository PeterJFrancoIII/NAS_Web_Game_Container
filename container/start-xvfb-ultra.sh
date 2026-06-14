#!/bin/sh
# Boot Xvfb at the max RA2 tier so RandR can expose 480p/720p/1080p to Wine, then
# shrink to the active RESOLUTION for 1:1 native capture.
set -eu

DISPLAY_ENV="${ULTRA_DISPLAY_ENV:-/home/commander/.ra2/display.env}"
if [ -f "$DISPLAY_ENV" ]; then
  # shellcheck disable=SC1090
  . "$DISPLAY_ENV"
fi

TARGET="${RESOLUTION:-1024x768}"
MAX_MODE="1440x1080"
DEPTH="${RA2_DISPLAY_DEPTH:-16}"
DISPLAY_NUM="${DISPLAY:-:1}"
DISPLAY_NUM="${DISPLAY_NUM#:}"
DISPLAY_TARGET=":${DISPLAY_NUM}"
export DISPLAY="$DISPLAY_TARGET"

if [ -x /opt/ra2/cleanup-xvfb-display.sh ]; then
  /bin/sh /opt/ra2/cleanup-xvfb-display.sh "$DISPLAY_NUM"
fi

log() {
  printf '[ultra-xvfb] %s\n' "$*" >&2
}

# Below max tier: start Xvfb at the exact capture size. Bootstrapping a 1440
# framebuffer and RandR-scaling down leaves the game on a 1080p surface and
# pegs CPU; RESOLUTION must be chosen before the game starts (no runtime switch).
if [ "$TARGET" != "$MAX_MODE" ]; then
  log "starting Xvfb at native ${TARGET} (no max-tier bootstrap)"
  exec /usr/bin/Xvfb "$DISPLAY_TARGET" -screen 0 "${TARGET}x${DEPTH}" -nolisten tcp
fi

read_display_dims() {
  xdpyinfo -display "$DISPLAY_TARGET" 2>/dev/null | awk '/dimensions:/{print $2; exit}'
}

start_xvfb() {
  mode="$1"
  shift
  /usr/bin/Xvfb "$DISPLAY_TARGET" -screen 0 "${mode}x${DEPTH}" "$@" -nolisten tcp &
  echo $!
}

# Phase 1: max framebuffer + RandR so RA2/Wine can enumerate tier modes.
XVFB_PID="$(start_xvfb "$MAX_MODE" +extension RANDR)"
cleanup() {
  if [ -n "${XVFB_PID:-}" ]; then
    kill "$XVFB_PID" 2>/dev/null || true
  fi
  if [ -x /opt/ra2/cleanup-xvfb-display.sh ]; then
    /bin/sh /opt/ra2/cleanup-xvfb-display.sh "$DISPLAY_NUM"
  fi
}
trap cleanup INT TERM

i=0
while [ "$i" -lt 30 ]; do
  if read_display_dims >/dev/null 2>&1; then
    break
  fi
  sleep 1
  i=$((i + 1))
done

if [ -x /opt/ra2/configure-display-modes.sh ]; then
  /bin/sh /opt/ra2/configure-display-modes.sh || log "tier mode registration incomplete"
fi

dims="$(read_display_dims)"
if [ "$TARGET" = "$MAX_MODE" ] && [ "$dims" = "$TARGET" ]; then
  log "active display ${TARGET} (max tier framebuffer)"
  wait "$XVFB_PID"
  exit 0
fi

# Phase 2: RandR can report the target size while the framebuffer stays at max
# tier — always restart at exact pixels for 1:1 capture below max resolution.
log "switching Xvfb from ${dims:-unknown} to ${TARGET} for native capture"
kill "$XVFB_PID" 2>/dev/null || true
wait "$XVFB_PID" 2>/dev/null || true
trap - INT TERM

exec /usr/bin/Xvfb "$DISPLAY_TARGET" -screen 0 "${TARGET}x${DEPTH}" -nolisten tcp
