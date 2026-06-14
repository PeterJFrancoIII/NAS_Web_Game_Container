#!/bin/sh
# Host-admin path: validate game id and write selection file. Not exposed to stream users.
set -eu

GAME_ID="${1:?game id required}"
SELECTION_FILE="${GAME_SELECTION_FILE:-/home/commander/.ra2/selected-game}"
STATE_DIR="$(dirname "$SELECTION_FILE")"

/bin/sh /opt/ra2/validate-game-id.sh "$GAME_ID"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
printf '%s\n' "$GAME_ID" >"$SELECTION_FILE"
chmod 600 "$SELECTION_FILE"
