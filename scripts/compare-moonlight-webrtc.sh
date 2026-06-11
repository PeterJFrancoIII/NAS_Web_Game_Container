#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

printf '== RA2 player stack (fallback) ==\n'
for c in ra2-player-1 ra2-player-2; do
  state="$(container_status "$c")"
  printf '%s: %s\n' "$c" "${state:-missing}"
done

printf '\n== Moonlight experiments ==\n'
for c in ra2-sunshine-experiment ra2-wolf-experiment; do
  state="$(container_status "$c")"
  printf '%s: %s\n' "$c" "${state:-not deployed}"
done

printf '\n== Comparison checklist ==\n'
cat <<'EOF'
| Metric              | WebRTC (legacy)     | Moonlight (target)   |
|---------------------|---------------------|----------------------|
| Protocol            | WebRTC/GStreamer    | GameStream RTSP+UDP  |
| Client              | Browser remote.html | Moonlight app        |
| Encode              | vah264enc+ximagesrc | VA-API direct        |
| Remote access       | Port forwards       | Tailscale direct     |
| Admin fallback      | noVNC vnc.html      | noVNC vnc.html       |
| Latency target      | 50-150ms+           | 10-20ms LAN          |
EOF

printf '\nRun diagnostics:\n'
printf '  sh scripts/check-moonlight-ready.sh\n'
printf '  sh scripts/check-webrtc-ice-reachability.sh\n'
printf '  sh scripts/check-tailscale-direct.sh\n'
