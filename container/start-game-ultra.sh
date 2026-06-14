#!/bin/sh
# Ultra game supervisor: show launcher menu, run selected game, return to menu on exit.

set -eu

DISPLAY_ENV="${ULTRA_DISPLAY_ENV:-/home/commander/.ra2/display.env}"
if [ -f "$DISPLAY_ENV" ]; then
  # shellcheck disable=SC1090
  . "$DISPLAY_ENV"
fi

GAME_LAUNCHER_ENABLED="${GAME_LAUNCHER_ENABLED:-1}"
SELECTION_FILE="${GAME_SELECTION_FILE:-/home/commander/.ra2/selected-game}"
STATE_DIR="$(dirname "$SELECTION_FILE")"

log() {
  printf '[ultra-game] %s\n' "$*"
}

wait_for_xvfb() {
  i=0
  while [ "$i" -lt 60 ]; do
    if pgrep -f "Xvfb ${DISPLAY:-:1}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  log "Xvfb ${DISPLAY:-:1} not running after 60s"
  return 1
}

show_launcher() {
  mkdir -p "$STATE_DIR"
  if [ "$GAME_LAUNCHER_ENABLED" != "1" ]; then
    printf '%s\n' "${DEFAULT_GAME_ID:-ra2}" >"$SELECTION_FILE"
    return 0
  fi
  log "showing game menu (CLI)"
  /bin/sh /opt/ra2/game-launcher.sh
}

read_selection() {
  if [ ! -f "$SELECTION_FILE" ]; then
    return 1
  fi
  tr -d ' \t\r\n' <"$SELECTION_FILE"
}

wait_for_xvfb || exit 1

if [ "$GAME_LAUNCHER_ENABLED" = "1" ]; then
  log "launcher mode enabled; games return to menu on exit"
  while true; do
    if [ ! -f "$SELECTION_FILE" ]; then
      show_launcher || {
        log "launcher failed; retrying in 3s"
        sleep 3
        continue
      }
    fi
    game_id="$(read_selection || true)"
    if [ -z "$game_id" ]; then
      log "no game selected; retrying launcher"
      sleep 1
      continue
    fi
    log "launching game profile: ${game_id}"
    /bin/sh /opt/ra2/run-game-session.sh "$game_id" || {
      log "session ended with errors for ${game_id}"
      rm -f "$SELECTION_FILE"
    }
    log "returning to game launcher"
    sleep 1
  done
fi

# Legacy single-game mode (player stacks without launcher).
exec /bin/sh /opt/ra2/run-game-session.sh "${DEFAULT_GAME_ID:-ra2}"
