#!/bin/sh
# Linux is case-sensitive; keep ra2.ini/ra2md.ini aliased to RA2MD.ini.
# Safe while gamemd is running (symlinks only, no config rewrites).
set -eu

LOG_ROOT="${ULTRA_GAME_LOG_ROOT:-/home/commander/ra2-logs-root}"
DIAGNOSTIC_DIR="${ULTRA_GAME_DIAGNOSTIC_DIR:-${LOG_ROOT}/player${PLAYER_ID:-unknown}}"
GAME_WORK="${ULTRA_GAME_WORK_DIR:-${DIAGNOSTIC_DIR}/game-work}"

[ -f "${GAME_WORK}/RA2MD.ini" ] || exit 0

cd "$GAME_WORK"
rm -f ra2.ini ra2md.ini
ln -sf RA2MD.ini ra2.ini
ln -sf RA2MD.ini ra2md.ini
