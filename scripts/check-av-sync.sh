#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

COMPOSE_DIR="${COMPOSE_DIR:-/volume2/Data/App_Development/ra2-lan-party/project}"
ENV_FILE="${ENV_FILE:-$COMPOSE_DIR/.env}"
PLAYER1="${PLAYER1:-ra2-player-1}"
PLAYER2="${PLAYER2:-ra2-player-2}"
MAX_AUDIO_START_MS="${MAX_AUDIO_START_MS:-1000}"
FAIL=0

pass() {
  printf '[OK] %s\n' "$1"
}

fail() {
  printf '[FAIL] %s\n' "$1"
  FAIL=1
}

exec_in() {
  run_docker exec "$1" sh -lc "$2"
}

check_plugin_constants() {
  container="$1"

  if exec_in "$container" 'grep -q "static #BUFFER_MIN_REMAIN = 3;" /opt/novnc/audio-plugin.js'; then
    pass "$container audio buffer keeps a smooth playback cushion"
  else
    fail "$container audio plugin buffer is too small for smooth playback"
  fi

  if exec_in "$container" 'grep -q "static #DRIFT_CHECK_INTERVAL = 2000;" /opt/novnc/audio-plugin.js && grep -q "static #TARGET_LATENCY = 1.0;" /opt/novnc/audio-plugin.js && grep -q "playbackRate = 1 + correction" /opt/novnc/audio-plugin.js && ! grep -q "this.#attachedEl.currentTime = Math.max(0, bufferEnd - targetLatency);" /opt/novnc/audio-plugin.js'; then
    pass "$container audio drift uses soft playback-rate correction"
  else
    fail "$container audio drift correction can cause periodic stalls or desync"
  fi

  if exec_in "$container" 'grep -q "static #DRIFT_MAX_TOLERANCE = 0.5;" /opt/novnc/audio-plugin.js'; then
    pass "$container audio drift tolerance favors smooth playback"
  else
    fail "$container audio drift tolerance is not tuned for smooth playback"
  fi

  if exec_in "$container" 'grep -q "window.location.protocol === '\''https:'\''" /opt/novnc/audio-plugin.js'; then
    pass "$container audio WebSocket follows HTTPS/WSS"
  else
    fail "$container audio WebSocket encryption does not follow page protocol"
  fi
}

check_audio_start_latency() {
  container="$1"

  output="$(
    exec_in "$container" 'python - <<'"'"'PY'"'"'
import socket
import sys
import time

start = time.monotonic()
sock = socket.create_connection(("127.0.0.1", 5711), timeout=2)
sock.settimeout(2)
sock.sendall(b"CD:opus\nSR:44100\n\n")

line = b""
while not line.endswith(b"\n"):
    chunk = sock.recv(1)
    if not chunk:
        raise RuntimeError("audio proxy closed before READY")
    line += chunk

if line.strip() != b"READY":
    raise RuntimeError(f"unexpected audio proxy response: {line!r}")

elapsed_ms = int((time.monotonic() - start) * 1000)
print(elapsed_ms)
sock.close()
PY'
  )" || {
    fail "$container audio proxy did not return READY after handshake"
    return
  }

  case "$output" in
    ''|*[!0-9]*)
      fail "$container audio startup latency probe returned unexpected output: $output"
      ;;
    *)
      if [ "$output" -le "$MAX_AUDIO_START_MS" ]; then
        pass "$container audio handshake completes in ${output}ms (<= ${MAX_AUDIO_START_MS}ms)"
      else
        fail "$container audio handshake completes in ${output}ms (> ${MAX_AUDIO_START_MS}ms)"
      fi
      ;;
  esac
}

check_proxy_low_latency_contract() {
  container="$1"

  if exec_in "$container" 'grep -q "DEFAULT_WEBM_CLUSTER_MS=.*100" /opt/ra2/audio-proxy.sh && grep -q "min-cluster-duration=\"\${cluster_ns}\"" /opt/ra2/audio-proxy.sh'; then
    pass "$container WebM/Opus cluster target is 100ms"
  else
    fail "$container WebM/Opus cluster target is not tuned for smooth playback"
  fi

  if exec_in "$container" 'grep -q "DEFAULT_OPUS_FRAME_MS=.*20" /opt/ra2/audio-proxy.sh && grep -q "frame-size=\"\${opus_frame_ms}\"" /opt/ra2/audio-proxy.sh'; then
    pass "$container Opus frame size is 20ms"
  else
    fail "$container Opus frame size is not tuned for smooth playback"
  fi

  if exec_in "$container" 'grep -q "DEFAULT_QUEUE_BUFFERS=.*8" /opt/ra2/audio-proxy.sh && grep -q "queue max-size-buffers=\"\${queue_buffers}\" leaky=downstream" /opt/ra2/audio-proxy.sh'; then
    pass "$container audio queue is bounded, leaky, and smooth"
  else
    fail "$container audio queue is not tuned for smooth playback"
  fi
}

cd "$COMPOSE_DIR"

for container in "$PLAYER1" "$PLAYER2"; do
  state="$(container_status "$container")"
  if [ "$state" = "running" ]; then
    pass "$container is running"
  else
    fail "$container state is ${state:-unknown}"
    continue
  fi

  check_plugin_constants "$container"
  check_proxy_low_latency_contract "$container"
  check_audio_start_latency "$container"
done

if [ -f "$ENV_FILE" ]; then
  nas_ip="$(read_env_value NAS_LAN_IP 192.168.0.193 "$ENV_FILE")"
  port1="$(read_env_value PLAYER1_HTTP_PORT 6081 "$ENV_FILE")"
  port2="$(read_env_value PLAYER2_HTTP_PORT 6082 "$ENV_FILE")"
  printf '\nAV sync URLs:\n'
  printf '  Player 1: https://%s:%s/vnc.html\n' "$nas_ip" "$port1"
  printf '  Player 2: https://%s:%s/vnc.html\n' "$nas_ip" "$port2"
fi

if [ "$FAIL" -ne 0 ]; then
  printf '\nAV sync verification failed.\n'
  exit 1
fi

printf '\nAV sync verification passed.\n'
