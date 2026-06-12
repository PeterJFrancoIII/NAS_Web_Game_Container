#!/bin/sh
# Remove stale Xvfb processes and lock files for the ultra display.
set -eu

DISPLAY_NUM="${1:-1}"
DISPLAY_NUM="${DISPLAY_NUM#:}"
LOCK="/tmp/.X${DISPLAY_NUM}-lock"
SOCKET="/tmp/.X11-unix/X${DISPLAY_NUM}"

if command -v pkill >/dev/null 2>&1; then
  pkill -f "Xvfb :${DISPLAY_NUM} " 2>/dev/null || true
fi

if [ -f "$LOCK" ]; then
  pid="$(cat "$LOCK" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 0.2
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$LOCK"
fi

if [ -e "$SOCKET" ]; then
  rm -f "$SOCKET"
fi
