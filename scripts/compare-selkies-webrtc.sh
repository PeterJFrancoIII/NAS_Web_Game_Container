#!/bin/sh
set -eu

# Side-by-side readiness check for zero-copy (Selkies) vs current WebRTC path.
# Does not modify production players.

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

CONTAINER="${RA2_WEBRTC_CONTAINER:-ra2-player-1}"
SELKIES_CONTAINER="${SELKIES_CONTAINER:-ra2-selkies-experiment}"

section() {
  printf '\n== %s ==\n' "$1"
}

section "Production WebRTC path (${CONTAINER})"
if [ "$(container_status "$CONTAINER")" = "running" ]; then
  run_docker exec "$CONTAINER" sh -lc '
    echo "capture=ximagesrc"
    env | grep -E "^WEBRTC_VIDEO_|^WEBRTC_LATENCY_PRESET=" || true
    gst-inspect-1.0 vah264enc 2>/dev/null | head -n 2 || echo "vah264enc missing"
    gst-inspect-1.0 vah265enc 2>/dev/null | head -n 2 || echo "vah265enc missing"
  '
  run_docker stats --no-stream "$CONTAINER" 2>/dev/null || true
else
  echo "WARN: ${CONTAINER} not running"
fi

section "Selkies zero-copy experiment (${SELKIES_CONTAINER})"
if [ "$(container_status "$SELKIES_CONTAINER")" = "running" ]; then
  run_docker exec "$SELKIES_CONTAINER" sh -lc '
    echo "capture=wayland/selkies"
    env | grep -E "SELKIES_|MESA_|INTEL_" || true
  ' 2>/dev/null || echo "Selkies container running but exec failed"
  run_docker stats --no-stream "$SELKIES_CONTAINER" 2>/dev/null || true
else
  echo "Selkies experiment not running."
  echo "Start with: docker compose --env-file .env -f compose.selkies-experiment.yaml up -d"
fi

section "Comparison checklist"
cat <<'EOF'
Measure both paths with the same client, resolution, and network:
  1. Glass-to-glass latency (click-to-pixel)
  2. docker stats CPU/RAM during play
  3. Browser stability (Safari target)
  4. RA2 menu/gameplay correctness

Production URL:  https://<NAS_LAN_IP>:6081/remote.html?signal=6083&input=6085
Selkies URL:     https://<NAS_LAN_IP>:6101

Promote Selkies only if latency is lower AND RA2 plays acceptably.
See docs/SELKIES_EXPERIMENT.md for go/no-go criteria.
EOF
