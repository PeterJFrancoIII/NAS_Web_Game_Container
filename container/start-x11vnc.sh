#!/bin/sh
set -eu

if [ "${RA2_ENABLE_NOVNC_FALLBACK:-1}" = "0" ]; then
  printf '[x11vnc] disabled (RA2_ENABLE_NOVNC_FALLBACK=0)\n' >&2
  exit 0
fi

display="${DISPLAY:-:1}"
attempt=1
while [ "$attempt" -le 30 ]; do
  if xdpyinfo -display "$display" >/dev/null 2>&1; then
    break
  fi
  if [ "$attempt" -eq 1 ]; then
    printf '[x11vnc] waiting for X display %s\n' "$display" >&2
  fi
  attempt=$((attempt + 1))
  sleep 1
done

if ! xdpyinfo -display "$display" >/dev/null 2>&1; then
  printf '[x11vnc] X display %s was not ready after 30s\n' "$display" >&2
  exit 1
fi

exec /usr/bin/x11vnc \
  -display "$display" \
  -localhost \
  -rfbport 5900 \
  -rfbauth /tmp/x11vnc.pass \
  -forever \
  -shared \
  -noxdamage \
  -repeat
