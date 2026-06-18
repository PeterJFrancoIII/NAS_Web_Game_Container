#!/bin/sh
# Register 480p / 720p / 1080p (4:3) modes on the Xvfb RandR output for Wine/RA2.
set -eu

DISPLAY_TARGET="${DISPLAY:-:1}"
export DISPLAY="$DISPLAY_TARGET"
DISPLAY_ENV="${ULTRA_DISPLAY_ENV:-/home/commander/.ra2/display.env}"
if [ -f "$DISPLAY_ENV" ]; then
  # shellcheck disable=SC1090
  . "$DISPLAY_ENV"
fi

ACTIVE="${RESOLUTION:-1024x768}"

log() {
  printf '[ultra-display] %s\n' "$*" >&2
}

read_display_dims() {
  xdpyinfo -display "$DISPLAY_TARGET" 2>/dev/null | awk '/dimensions:/{print $2; exit}'
}

randr_output() {
  xrandr 2>/dev/null | awk '/ connected/{print $1; exit}'
}

wait_for_display() {
  i=0
  while [ "$i" -lt 30 ]; do
    if read_display_dims >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

modeline_for_mode() {
  case "$1" in
    640x480)   printf '%s\n' '23.75 640 656 720 864 480 483 487 525' ;;
    800x600)   printf '%s\n' '36.00 800 824 896 1024 600 601 603 625' ;;
    960x720)   printf '%s\n' '55.00 960 992 1088 1248 720 723 727 750' ;;
    1024x768)  printf '%s\n' '65.00 1024 1048 1184 1344 768 771 777 806' ;;
    1440x1080) printf '%s\n' '129.00 1440 1528 1672 1904 1080 1083 1087 1120' ;;
    *) return 1 ;;
  esac
}

add_mode() {
  res="$1"
  output="$2"
  name="${res}"

  if xrandr 2>/dev/null | grep -Eq "^[[:space:]]+${name}[[:space:]]"; then
    return 0
  fi

  timing="$(modeline_for_mode "$res")" || return 1
  # shellcheck disable=SC2086
  xrandr --newmode "${name}" $timing 2>/dev/null || true
  xrandr --addmode "$output" "$name" 2>/dev/null || true
}

set_active_mode() {
  res="$1"
  output="$2"
  xrandr --output "$output" --mode "$res" 2>/dev/null
}

if ! wait_for_display; then
  log "X display ${DISPLAY_TARGET} not ready for RandR mode setup"
  exit 1
fi

output="$(randr_output)"
if [ -z "$output" ]; then
  output="screen"
fi

# Keep in sync with GAME_DISPLAY_MODES in ra2-stream-gateway.py
for mode in 640x480 800x600 960x720 1024x768 1440x1080; do
  add_mode "$mode" "$output" || true
done

if set_active_mode "$ACTIVE" "$output"; then
  actual="$(read_display_dims)"
  log "tier modes registered; active=${ACTIVE} (xdpyinfo=${actual:-unknown})"
  exit 0
fi

actual="$(read_display_dims)"
log "tier modes registered; could not RandR-switch to ${ACTIVE} (xdpyinfo=${actual:-unknown})"
exit 1
