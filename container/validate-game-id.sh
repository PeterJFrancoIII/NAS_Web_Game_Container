#!/bin/sh
# Allow only manifest game ids (no paths, shell metacharacters, or free-form commands).
set -eu

GAME_ID="${1:?game id required}"
GAMES_MANIFEST="${GAMES_MANIFEST:-/opt/ra2/config/games.json}"

case "$GAME_ID" in
  *[!a-zA-Z0-9_-]*|'') exit 1 ;;
esac

python3 - "$GAME_ID" "$GAMES_MANIFEST" <<'PY'
import json, sys
game_id, path = sys.argv[1], sys.argv[2]
manifest = json.load(open(path, encoding="utf-8"))
sys.exit(0 if game_id in manifest else 1)
PY
