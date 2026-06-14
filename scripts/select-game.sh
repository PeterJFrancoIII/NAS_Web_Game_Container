#!/bin/sh
# Host-admin only: authorize a game launch in a running player container.
set -eu

CONTAINER="${1:?container name (e.g. ra2-player-1)}"
GAME_ID="${2:?game id (e.g. ra2 or aoe2)}"
HOST="${NAS_HOST:-MediaServer2}"

case "$GAME_ID" in
  *[!a-zA-Z0-9_-]*|'')
    echo "Invalid game id: $GAME_ID" >&2
    exit 1
    ;;
esac

ssh "$HOST" "sudo -n /usr/local/bin/docker exec '$CONTAINER' /bin/sh /opt/ra2/secure-game-select.sh '$GAME_ID'"
printf 'Authorized game %s for %s on %s\n' "$GAME_ID" "$CONTAINER" "$HOST"
