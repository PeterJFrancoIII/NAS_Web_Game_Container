#!/bin/sh
# Lightweight game picker — no GUI, no interactive shell, no OS access for stream users.
# Game choice is written only via secure-game-select.sh (browser gateway or host admin).

set -eu

GAMES_MANIFEST="${GAMES_MANIFEST:-/opt/ra2/config/games.json}"
SELECTION_FILE="${GAME_SELECTION_FILE:-/home/commander/.ra2/selected-game}"
STATE_DIR="$(dirname "$SELECTION_FILE")"
POLL_INTERVAL="${GAME_MENU_POLL_S:-1}"
MENU_TIMEOUT="${GAME_MENU_TIMEOUT:-0}"
DEFAULT_GAME="${GAME_MENU_DEFAULT:-ra2}"

log() {
  printf '[game-menu] %s\n' "$*"
}

list_games() {
  python3 - "$GAMES_MANIFEST" <<'PY'
import json, sys
from pathlib import Path
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
available = []
for game_id, profile in manifest.items():
    assets = Path(profile["assetsPath"])
    exe = assets / profile["gameExe"]
    if exe.is_file():
        available.append((game_id, profile.get("title", game_id)))
for game_id, title in available:
    print(f"{game_id}\t{title}")
PY
}

game_installed() {
  /bin/sh /opt/ra2/validate-game-id.sh "$1" && list_games | awk -F '\t' -v id="$1" '$1 == id { found=1 } END { exit found ? 0 : 1 }'
}

write_selection() {
  /bin/sh /opt/ra2/secure-game-select.sh "$1"
}

clear_stream_display() {
  if [ -n "${DISPLAY:-}" ] && command -v xsetroot >/dev/null 2>&1; then
    xsetroot -solid "#0f1419" 2>/dev/null || true
  fi
}

if [ ! -f "$GAMES_MANIFEST" ]; then
  log "missing manifest: $GAMES_MANIFEST"
  exit 1
fi

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

games="$(list_games || true)"
if [ -z "$games" ]; then
  log "no games with installed assets found"
  exit 1
fi

count="$(printf '%s\n' "$games" | wc -l | tr -d ' ')"
if [ "$count" -lt 1 ]; then
  log "no games with installed assets found"
  exit 1
fi

# Never auto-launch a game at boot — always wait for an explicit browser/admin selection.
if [ -n "${GAME_REQUEST:-}" ] && game_installed "$GAME_REQUEST"; then
  log "using GAME_REQUEST=${GAME_REQUEST}"
  write_selection "$GAME_REQUEST"
  exit 0
fi

rm -f "$SELECTION_FILE"
/bin/sh /opt/ra2/game-session-state.sh waiting
clear_stream_display

log "waiting for browser game selection"
log "installed titles:"
printf '%s\n' "$games" | awk -F '\t' '{ printf "  %s — %s\n", $1, $2 }'
if [ "$MENU_TIMEOUT" -gt 0 ]; then
  log "will default to ${DEFAULT_GAME} after ${MENU_TIMEOUT}s if nothing is selected"
else
  log "stream display idle until a game is selected"
fi

started="$(date +%s)"
while true; do
  if [ -f "$SELECTION_FILE" ]; then
    game_id="$(tr -d ' \t\r\n' <"$SELECTION_FILE")"
    if game_installed "$game_id"; then
      log "selected: ${game_id}"
      exit 0
    fi
    log "rejected invalid selection; waiting for authorized game id"
    rm -f "$SELECTION_FILE"
  fi

  if [ "$MENU_TIMEOUT" -gt 0 ] && [ "$(($(date +%s) - started))" -ge "$MENU_TIMEOUT" ]; then
    if game_installed "$DEFAULT_GAME"; then
      log "timeout; defaulting to ${DEFAULT_GAME}"
      write_selection "$DEFAULT_GAME"
      exit 0
    fi
    log "timeout and default game '${DEFAULT_GAME}' unavailable"
    exit 1
  fi

  sleep "$POLL_INTERVAL"
done
