#!/bin/sh
# Restart Pulse + stream-gateway so native capture and transport audio align.
# Run on the NAS (sudo required for Docker on Synology):
#   sudo sh scripts/restart-audio-ultra.sh
#   sudo sh scripts/restart-audio-ultra.sh ra2-player-dev
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib.sh"

SERVICE="${1:-}"
if [ -n "$SERVICE" ]; then
  SERVICES="$SERVICE"
else
  SERVICES="ra2-player-1 ra2-player-2 ra2-player-dev"
fi

restart_audio_in() {
  container="$1"
  if [ "$(container_status "$container")" != "running" ]; then
    echo "[audio] skip $container (not running)"
    return 0
  fi
  run_docker exec "$container" sh -lc '
    set -eu
    RATE="${ULTRA_AUDIO_RATE:-48000}"
    ENC="${ULTRA_AUDIO_CODEC:-opus}"
    pkill -f /opt/ra2/stream-helper 2>/dev/null || true
    /bin/sh /opt/ra2/sync-audio-transport.sh "$RATE" "$RATE" "$ENC"
    supervisorctl -c /opt/ra2/supervisord.conf restart pulseaudio
    sleep 2
    supervisorctl -c /opt/ra2/supervisord.conf restart game
    supervisorctl -c /opt/ra2/supervisord.conf restart stream-gateway
  '
  echo "[audio] restarted pulseaudio + game + stream-gateway in $container (${ULTRA_AUDIO_RATE:-48000}Hz)"
}

for svc in $SERVICES; do
  restart_audio_in "$svc"
done

echo "[audio] done"
