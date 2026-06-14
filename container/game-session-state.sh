#!/bin/sh
# Track launcher/game session phase for the browser gateway and game supervisor.
set -eu

SESSION_STATE_FILE="${GAME_SESSION_STATE:-/home/commander/.ra2/session-state}"

write_session_state() {
  phase="${1:?phase required}"
  game_id="${2:-}"
  mkdir -p "$(dirname "$SESSION_STATE_FILE")"
  {
    printf 'phase=%s\n' "$phase"
    printf 'game=%s\n' "$game_id"
  } >"$SESSION_STATE_FILE"
  chmod 600 "$SESSION_STATE_FILE" 2>/dev/null || true
}

case "${1:-}" in
  idle|waiting) write_session_state waiting "" ;;
  running) write_session_state running "${2:?game id required}" ;;
  switching) write_session_state switching "${2:?game id required}" ;;
  *) exit 1 ;;
esac
