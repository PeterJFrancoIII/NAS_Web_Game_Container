#!/bin/sh
# Apply ultra-low-latency tracks on NAS. Run on MediaServer2 with sudo:
#   cd /volume2/Data/App_Development/ra2-lan-party/project
#   sudo sh scripts/apply-ultra-low-latency.sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

cd "$SCRIPT_DIR/.."

if [ "$(id -u)" -ne 0 ] && ! sudo -n true >/dev/null 2>&1; then
  echo "Run with sudo: sudo sh scripts/apply-ultra-low-latency.sh"
  exit 1
fi

echo "=== apply ultra-low-latency $(date) ==="

export RA2_COMPOSE_WEBRTC=1
export RA2_COMPOSE_WEBRTC_UDP="${RA2_COMPOSE_WEBRTC_UDP:-0}"

echo "=== recreate players (no-build) ==="
run_compose .env up -d --no-build --force-recreate ra2-player-1 ra2-player-2

echo "=== ensure GStreamer VA plugins (vah264enc/vah265enc) ==="
for c in ra2-player-1 ra2-player-2; do
  run_docker exec -u root "$c" sh -lc '
    if ! gst-inspect-1.0 vah264enc >/dev/null 2>&1; then
      echo "installing gst-plugin-va in container"
      pacman -Sy --noconfirm gst-plugin-va
    fi
    gst-inspect-1.0 vah264enc 2>/dev/null | head -n 2 || echo "vah264enc still missing"
    gst-inspect-1.0 vah265enc 2>/dev/null | head -n 2 || echo "vah265enc still missing"
  '
done

echo "=== recompile webrtc-media-helper in both containers ==="
for c in ra2-player-1 ra2-player-2; do
  run_docker exec "$c" sh -lc '
    set -eu
    if [ ! -f /opt/ra2/webrtc-media-helper.c ]; then
      echo "helper source missing"
      exit 1
    fi
    gcc /opt/ra2/webrtc-media-helper.c -o /opt/ra2/webrtc-media-helper \
      $(pkg-config --cflags --libs gstreamer-1.0 gstreamer-webrtc-1.0 gstreamer-sdp-1.0)
    chmod +x /opt/ra2/webrtc-media-helper
    echo "helper recompiled"
    gst-inspect-1.0 vah264enc 2>/dev/null | head -n 2 || echo "vah264enc missing"
    gst-inspect-1.0 vah265enc 2>/dev/null | head -n 2 || echo "vah265enc missing"
    test -r /dev/uinput && echo "uinput readable" || echo "uinput missing (xdotool fallback)"
  '
done

echo "=== host preflight ==="
sh "$SCRIPT_DIR/check-low-latency-host.sh" || true
sh "$SCRIPT_DIR/check-transcode.sh" ra2-player-1 || true

echo "=== done ==="
echo "Stable play: remote.html?signal=6083&input=6085"
echo "HEVC test: set WEBRTC_VIDEO_CODEC=H265 in .env, recreate, open remote.html?codec=H265"
echo "UDP test:  RA2_COMPOSE_WEBRTC_UDP=1 sudo sh scripts/redeploy-webrtc-udp.sh"
