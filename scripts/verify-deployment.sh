#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

COMPOSE_DIR="${COMPOSE_DIR:-/volume2/Data/App_Development/ra2-lan-party/project}"
ENV_FILE="${ENV_FILE:-$COMPOSE_DIR/.env}"
PLAYER1="${PLAYER1:-Cloud_Gaming_Player1}"
PLAYER2="${PLAYER2:-Cloud_Gaming_Player2}"
FAIL=0

pass() {
  printf '[OK] %s\n' "$1"
}

fail() {
  printf '[FAIL] %s\n' "$1"
  FAIL=1
}

note() {
  printf '[..] %s\n' "$1"
}

exec_in() {
  run_docker exec "$1" sh -lc "$2"
}

cd "$COMPOSE_DIR"

note "Container status"
if ! run_docker ps -a --filter name=Cloud_Gaming_Player --format 'table {{.Names}}\t{{.Status}}'; then
  fail "Could not query Docker"
  exit 1
fi

for container in "$PLAYER1" "$PLAYER2"; do
  state="$(container_status "$container")"
  if [ "$state" = "running" ]; then
    pass "$container is running"
  else
    fail "$container state is ${state:-unknown}"
  fi
done

if [ -f "$ENV_FILE" ]; then
  note "Player serials"
  serial1="$(read_env_value PLAYER1_SERIAL "" "$ENV_FILE")"
  serial2="$(read_env_value PLAYER2_SERIAL "" "$ENV_FILE")"
  if [ -z "$serial1" ] || [ -z "$serial2" ]; then
    fail "PLAYER1_SERIAL and PLAYER2_SERIAL must both be set"
  elif [ "$serial1" = "$serial2" ]; then
    fail "PLAYER1_SERIAL and PLAYER2_SERIAL must differ"
  else
    pass "PLAYER1_SERIAL and PLAYER2_SERIAL differ"
  fi
else
  fail "Environment file not found: $ENV_FILE"
fi

note "Browser audio stack"
for container in "$PLAYER1" "$PLAYER2"; do
  if exec_in "$container" 'ps -ef | grep "[p]ulseaudio" >/dev/null'; then
    pass "$container PulseAudio is running"
  else
    fail "$container PulseAudio is not running"
  fi

  if exec_in "$container" 'ps -ef | grep "[a]udio-proxy" >/dev/null'; then
    pass "$container audio proxy is running"
  else
    fail "$container audio proxy is not running"
  fi

  if exec_in "$container" 'python -c "import socket; s=socket.create_connection((\"127.0.0.1\", 5711), timeout=2); s.close()"'; then
    pass "$container audio proxy is listening on port 5711"
  else
    fail "$container audio proxy is not listening on port 5711"
  fi
done

note "TLS and noVNC browser endpoint"
if tls_material_present "$ENV_FILE"; then
  if tls_key_usable_by_container "$ENV_FILE"; then
    pass "TLS certificate and key are present for container uid 1000"
  else
    fail "TLS key is not readable by container uid 1000 — run: sh scripts/ensure-tls.sh"
  fi
else
  fail "TLS is not configured — run: sh scripts/ensure-tls.sh"
fi

for container in "$PLAYER1" "$PLAYER2"; do
  if exec_in "$container" '/bin/sh /opt/ra2/healthcheck-novnc.sh'; then
    if exec_in "$container" 'test -f /opt/ra2/tls/cert.pem && test -f /opt/ra2/tls/key.pem'; then
      pass "$container noVNC returns HTTPS 200"
    else
      pass "$container noVNC returns HTTP 200"
      printf '[WARN] %s is serving plain HTTP — noVNC requires HTTPS for full functionality (audio, crypto). Run scripts/ensure-tls.sh\n' "$container"
    fi
  else
    fail "$container noVNC is not reachable on port 6080"
  fi

  audio_ok=0
  attempt=1
  while [ "$attempt" -le 3 ]; do
    if exec_in "$container" 'printf "CD:opus\nSR:44100\n\n" | socat - TCP:127.0.0.1:5711' 2>/dev/null | head -n 1 | grep -q '^READY'; then
      audio_ok=1
      break
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  if [ "$audio_ok" -eq 1 ]; then
    pass "$container audio proxy handshake returns READY"
  else
    fail "$container audio proxy handshake failed"
  fi
done

note "Audio/video sync budget"
if sh "$SCRIPT_DIR/check-av-sync.sh"; then
  pass "audio/video sync budget passed"
else
  fail "audio/video sync budget failed"
fi

note "Host prerequisites (Moonlight primary path)"
if sh "$SCRIPT_DIR/check-host-prerequisites.sh" 2>/dev/null; then
  pass "host prerequisites passed (VA-API, uinput, RAM)"
else
  printf '[WARN] host prerequisites not met — see docs/MOONLIGHT_EXPERIMENT.md\n'
  printf '       Run: sh scripts/check-host-prerequisites.sh\n'
fi

if sh "$SCRIPT_DIR/check-low-latency-host.sh" 2>/dev/null; then
  pass "low-latency host check passed"
else
  printf '[WARN] low-latency host check reported warnings\n'
fi

if [ "${RA2_COMPOSE_MOONLIGHT:-0}" = "1" ] || [ "${RA2_COMPOSE_WOLF:-0}" = "1" ]; then
  note "Moonlight experiments"
  if sh "$SCRIPT_DIR/check-moonlight-ready.sh"; then
    pass "Moonlight readiness passed"
  else
    fail "Moonlight readiness failed"
  fi
fi

if [ "${RA2_COMPOSE_TAILSCALE:-0}" = "1" ]; then
  note "Tailscale direct path"
  if sh "$SCRIPT_DIR/check-tailscale-direct.sh"; then
    pass "Tailscale direct-path check passed"
  else
    printf '[WARN] Tailscale may be using DERP relay — see docs/TAILSCALE.md\n'
  fi
fi

if [ "${RA2_COMPOSE_WEBRTC:-0}" = "1" ]; then
  note "WebRTC legacy fallback"
  if sh "$SCRIPT_DIR/check-webrtc-ready.sh"; then
    pass "WebRTC readiness passed"
  else
    fail "WebRTC readiness failed"
  fi
  if sh "$SCRIPT_DIR/check-webrtc-ice-reachability.sh" 2>/dev/null; then
    pass "WebRTC ICE reachability passed"
  else
    printf '[WARN] WebRTC ICE/media ports may be blocked upstream\n'
    printf '       Run: sh scripts/check-webrtc-ice-reachability.sh\n'
  fi
fi

note "Wine prefix and game process"
for container in "$PLAYER1" "$PLAYER2"; do
  if exec_in "$container" 'test -f /home/commander/.wine/drive_c/windows/system32/kernel32.dll && test -f /home/commander/.wine/drive_c/windows/syswow64/kernel32.dll'; then
    pass "$container Wine prefix has 64-bit and WoW64 kernel32.dll"
  else
    fail "$container Wine prefix is incomplete"
  fi

  if exec_in "$container" 'ps -ef | grep -Ei "RA2MD|gamemd" | grep -v grep >/dev/null'; then
    pass "$container game process is running"
  else
    fail "$container game process is not running"
  fi
done

note "Host i915 media engine (DS225+/DS425+)"
if sh "$SCRIPT_DIR/check-host-transcode.sh"; then
  pass "host i915 media engine is ready"
else
  printf '[WARN] host i915 media engine is not ready (Synology default GuC/HuC disabled)\n'
  printf '       Run: sudo sh scripts/enable-host-transcode.sh\n'
fi

note "VA-API / FFmpeg transcoding (optional on DS225+)"
if sh "$SCRIPT_DIR/check-transcode.sh" "$PLAYER1"; then
  pass "hardware transcode probe passed for $PLAYER1"
else
  printf '[WARN] hardware transcode is not available yet on this NAS host (GuC/HuC disabled / VAProfileNone)\n'
  printf '       RA2 browser play is unaffected; see docs/NAS_DEPLOY_STATUS.md\n'
  if [ "${VERIFY_STRICT_TRANSCODE:-0}" = "1" ]; then
    fail "strict transcode verification requested and failed for $PLAYER1"
  fi
fi

if [ -f "$ENV_FILE" ]; then
  port1="$(read_env_value PLAYER1_HTTP_PORT 6081 "$ENV_FILE")"
  port2="$(read_env_value PLAYER2_HTTP_PORT 6082 "$ENV_FILE")"
  nas_ip="$(read_env_value NAS_LAN_IP 192.168.0.193 "$ENV_FILE")"
  public_host="$(read_env_value NAS_PUBLIC_HOSTNAME "" "$ENV_FILE")"
  tls_dir="$(read_env_value TLS_DIR /volume2/Data/App_Development/ra2-lan-party/tls "$ENV_FILE")"
  scheme="http"
  if [ -f "$tls_dir/cert.pem" ] && [ -f "$tls_dir/key.pem" ]; then
    scheme="https"
  fi
  printf '\nBrowser URLs:\n'
  printf '  Player 1 LAN: %s://%s:%s/vnc.html\n' "$scheme" "$nas_ip" "$port1"
  printf '  Player 2 LAN: %s://%s:%s/vnc.html\n' "$scheme" "$nas_ip" "$port2"
  if [ -n "$public_host" ]; then
    printf '  Player 1 remote: %s://%s:%s/vnc.html\n' "$scheme" "$public_host" "$port1"
    printf '  Player 2 remote: %s://%s:%s/vnc.html\n' "$scheme" "$public_host" "$port2"
  fi
  if [ "${RA2_COMPOSE_WEBRTC:-0}" = "1" ]; then
    signal1="$(read_env_value PLAYER1_WEBRTC_SIGNAL_PORT 6083 "$ENV_FILE")"
    signal2="$(read_env_value PLAYER2_WEBRTC_SIGNAL_PORT 6084 "$ENV_FILE")"
    input1="$(read_env_value PLAYER1_WEBRTC_INPUT_PORT 6085 "$ENV_FILE")"
    input2="$(read_env_value PLAYER2_WEBRTC_INPUT_PORT 6086 "$ENV_FILE")"
    udp1_min="$(read_env_value PLAYER1_WEBRTC_UDP_MIN 62001 "$ENV_FILE")"
    udp1_max="$(read_env_value PLAYER1_WEBRTC_UDP_MAX 62020 "$ENV_FILE")"
    udp2_min="$(read_env_value PLAYER2_WEBRTC_UDP_MIN 62021 "$ENV_FILE")"
    udp2_max="$(read_env_value PLAYER2_WEBRTC_UDP_MAX 62040 "$ENV_FILE")"
    host="$nas_ip"
    if [ -n "$public_host" ]; then
      host="$public_host"
    fi
    printf '\nWebRTC legacy fallback URLs:\n'
    printf '  Player 1: %s://%s:%s/remote.html?signal=%s&input=%s\n' "$scheme" "$host" "$port1" "$signal1" "$input1"
    printf '  Player 2: %s://%s:%s/remote.html?signal=%s&input=%s\n' "$scheme" "$host" "$port2" "$signal2" "$input2"
    printf '  UDP forwards: %s-%s (player 1), %s-%s (player 2)\n' "$udp1_min" "$udp1_max" "$udp2_min" "$udp2_max"
  fi
  if [ "$scheme" = "http" ]; then
    printf '\n[WARN] Use HTTPS to avoid noVNC secure-context crashes. See docs/HTTPS.md\n'
  fi
fi

if [ "$FAIL" -ne 0 ]; then
  printf '\nDeployment verification failed.\n'
  exit 1
fi

printf '\nDeployment verification passed.\n'
