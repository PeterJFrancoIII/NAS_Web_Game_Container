#!/bin/sh
# Boot-time / dev-only: restart Xvfb at RESOLUTION before gamemd starts.
# The stream gateway never calls this; resolution is fixed at container boot and game launch.
set -eu

RESOLUTION="${1:-}"
if [ -z "$RESOLUTION" ] || ! printf '%s' "$RESOLUTION" | grep -Eq '^[0-9]+x[0-9]+$'; then
  printf '[ultra-display] invalid resolution: %s\n' "$RESOLUTION" >&2
  exit 1
fi

DISPLAY_ENV="${ULTRA_DISPLAY_ENV:-/home/commander/.ra2/display.env}"
DEPTH="${RA2_DISPLAY_DEPTH:-16}"
GAME_PROCESS="${ULTRA_GAME_PROCESS:-gamemd.exe}"
READY_TIMEOUT="${ULTRA_GAME_READY_TIMEOUT:-120}"
DISPLAY_TARGET="${DISPLAY:-:1}"
SUPERVISOR_CONFIG="${ULTRA_SUPERVISOR_CONFIG:-/opt/ra2/supervisord.conf}"

mkdir -p "$(dirname "$DISPLAY_ENV")"
printf 'RESOLUTION=%s\nRA2_DISPLAY_DEPTH=%s\n' "$RESOLUTION" "$DEPTH" >"$DISPLAY_ENV"
export RESOLUTION RA2_DISPLAY_DEPTH="$DEPTH" DISPLAY="$DISPLAY_TARGET"

log() {
  printf '[ultra-display] %s\n' "$*" >&2
}

read_display_dims() {
  xdpyinfo -display "$DISPLAY_TARGET" 2>/dev/null | awk '/dimensions:/{print $2; exit}'
}

live_game_count() {
  ps -eo stat=,comm= 2>/dev/null | awk -v name="$GAME_PROCESS" '$2 == name && $1 !~ /^Z/ { count++ } END { print count + 0 }'
}

wait_for_xvfb() {
  i=0
  while [ "$i" -lt 45 ]; do
    dims="$(read_display_dims)"
    if [ "$dims" = "$RESOLUTION" ]; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

wait_for_game() {
  i=0
  while [ "$i" -lt "$READY_TIMEOUT" ]; do
    if [ "$(live_game_count)" -gt 0 ]; then
      return 0
    fi
    sleep 2
    i=$((i + 2))
  done
  return 1
}

ctl() {
  supervisorctl -c "$SUPERVISOR_CONFIG" "$@"
}

log "applying native display ${RESOLUTION}x${DEPTH}"

if ! ctl status >/dev/null 2>&1; then
  log "supervisorctl unavailable; cannot apply display change safely"
  exit 1
fi

if [ "$(live_game_count)" -gt 0 ]; then
  current="$(read_display_dims)"
  log "gamemd is running; refusing display change to ${RESOLUTION} (current=${current:-unknown})"
  exit 0
fi

current="$(read_display_dims)"
if [ "$current" = "$RESOLUTION" ]; then
  log "display already at ${RESOLUTION}"
  if [ "$(live_game_count)" -gt 0 ]; then
    exit 0
  fi
  ctl start game || exit 1
  wait_for_game && exit 0
  log "gamemd did not become ready within ${READY_TIMEOUT}s"
  exit 1
fi

ctl stop game openbox xvfb || true
if [ -x /opt/ra2/cleanup-xvfb-display.sh ]; then
  /bin/sh /opt/ra2/cleanup-xvfb-display.sh "${DISPLAY_TARGET#:}"
fi
sleep 1
ctl start xvfb || exit 1
if ! wait_for_xvfb; then
  actual="$(read_display_dims)"
  log "Xvfb did not reach ${RESOLUTION} (got ${actual:-unknown})"
  ctl start game || true
  exit 1
fi
ctl start openbox || exit 1
ctl start game || exit 1

if wait_for_game; then
  actual="$(read_display_dims)"
  if [ -x /opt/ra2/sync-game-transport.sh ]; then
    width="${RESOLUTION%x*}"
    height="${RESOLUTION#*x}"
    fps="${ULTRA_VIDEO_FPS:-24}"
    /bin/sh /opt/ra2/sync-game-transport.sh "$fps" "$width" "$height" || true
  fi
  log "gamemd ready at ${RESOLUTION} (xdpyinfo=${actual:-unknown})"
  exit 0
fi

log "gamemd did not become ready within ${READY_TIMEOUT}s"
exit 1
