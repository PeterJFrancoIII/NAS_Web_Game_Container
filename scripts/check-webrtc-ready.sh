#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

COMPOSE_DIR="${COMPOSE_DIR:-/volume2/Data/App_Development/ra2-lan-party/project}"
ENV_FILE="${ENV_FILE:-$COMPOSE_DIR/.env}"
PLAYER1="${PLAYER1:-ra2-player-1}"
PLAYER2="${PLAYER2:-ra2-player-2}"
FAIL=0

pass() { printf '[OK] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=1; }
note() { printf '[..] %s\n' "$1"; }

exec_in() {
  run_docker exec "$1" sh -lc "$2"
}

if [ "${RA2_COMPOSE_WEBRTC:-0}" != "1" ]; then
  note "WebRTC overlay disabled (RA2_COMPOSE_WEBRTC=${RA2_COMPOSE_WEBRTC:-0})"
  exit 0
fi

note "WebRTC process and port checks"
for container in "$PLAYER1" "$PLAYER2"; do
  if exec_in "$container" 'ps -ef | grep "[w]ebrtc-media.py" >/dev/null'; then
    pass "$container WebRTC media process is running"
  else
    fail "$container WebRTC media process is not running"
  fi

  if exec_in "$container" 'ps -ef | grep "[i]nput-proxy.py" >/dev/null'; then
    pass "$container WebRTC input proxy is running"
  else
    fail "$container WebRTC input proxy is not running"
  fi

  if exec_in "$container" 'test -f /opt/novnc/remote.html && test -f /opt/novnc/remote-play.js'; then
    pass "$container remote-play page is installed"
  else
    fail "$container remote-play page is missing"
  fi

  signal_port="$(exec_in "$container" 'printf %s "$WEBRTC_SIGNAL_PORT"')"
  input_port="$(exec_in "$container" 'printf %s "$WEBRTC_INPUT_PORT"')"
  udp_min="$(exec_in "$container" 'printf %s "$WEBRTC_UDP_PORT_MIN"')"
  udp_max="$(exec_in "$container" 'printf %s "$WEBRTC_UDP_PORT_MAX"')"

  if [ -n "$signal_port" ] && exec_in "$container" "python -c \"import socket; s=socket.create_connection(('127.0.0.1', ${signal_port}), timeout=2); s.close()\""; then
    pass "$container WebRTC signaling port ${signal_port} is listening"
  else
    fail "$container WebRTC signaling port is not listening"
  fi

  if [ -n "$input_port" ] && exec_in "$container" "python -c \"import socket; s=socket.create_connection(('127.0.0.1', ${input_port}), timeout=2); s.close()\""; then
    pass "$container WebRTC input port ${input_port} is listening"
  else
    fail "$container WebRTC input port is not listening"
  fi

  if [ -n "$udp_min" ] && [ -n "$udp_max" ]; then
    pass "$container WebRTC UDP range configured (${udp_min}-${udp_max})"
  else
    fail "$container WebRTC UDP range is not configured"
  fi
done

if [ "$FAIL" -ne 0 ]; then
  printf '\nWebRTC readiness check failed.\n'
  printf 'Run scripts/check-webrtc-ice-reachability.sh after a browser connects for media port diagnostics.\n'
  exit 1
fi

printf '\nWebRTC readiness check passed.\n'
printf 'Note: WebRTC is legacy fallback — primary path is Moonlight (docs/MOONLIGHT_EXPERIMENT.md).\n'
printf 'Run scripts/check-webrtc-ice-reachability.sh to verify ICE/media port reachability.\n'
