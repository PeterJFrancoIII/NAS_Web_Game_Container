#!/bin/sh
# Diagnose WebRTC ICE/media port reachability for remote play troubleshooting.
# Run on the NAS (or any host that can reach the advertised ICE host).
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

ENV_FILE="${ENV_FILE:-.env}"
CONTAINER="${RA2_WEBRTC_CONTAINER:-ra2-player-1}"
ICE_HOST="${WEBRTC_ICE_CANDIDATE_HOST:-$(read_env_value WEBRTC_ICE_CANDIDATE_HOST "" "$ENV_FILE")}"
PUBLIC_HOST="${NAS_PUBLIC_HOSTNAME:-$(read_env_value NAS_PUBLIC_HOSTNAME "" "$ENV_FILE")}"
LAN_IP="${NAS_LAN_IP:-$(read_env_value NAS_LAN_IP 192.168.0.193 "$ENV_FILE")}"
UDP_MIN="${PLAYER1_WEBRTC_UDP_MIN:-$(read_env_value PLAYER1_WEBRTC_UDP_MIN 62001 "$ENV_FILE")}"
UDP_MAX="${PLAYER1_WEBRTC_UDP_MAX:-$(read_env_value PLAYER1_WEBRTC_UDP_MAX 62020 "$ENV_FILE")}"
SIGNAL_PORT="${PLAYER1_WEBRTC_SIGNAL_PORT:-$(read_env_value PLAYER1_WEBRTC_SIGNAL_PORT 6083 "$ENV_FILE")}"
WARN=0

warn() { printf 'WARN: %s\n' "$1"; WARN=1; }
ok() { printf 'OK: %s\n' "$1"; }
section() { printf '\n== %s ==\n' "$1"; }

probe_tcp() {
  host="$1"
  port="$2"
  if python3 - "$host" "$port" <<'PY' 2>/dev/null
import socket, sys
host, port = sys.argv[1], int(sys.argv[2])
s = socket.create_connection((host, port), timeout=3)
s.close()
PY
  then
    ok "TCP ${host}:${port} reachable"
    return 0
  fi
  warn "TCP ${host}:${port} not reachable (timeout/refused)"
  return 1
}

section "ICE candidate host"
if [ -n "$ICE_HOST" ]; then
  ok "WEBRTC_ICE_CANDIDATE_HOST=${ICE_HOST}"
else
  warn "WEBRTC_ICE_CANDIDATE_HOST unset — remote browsers may receive LAN-only candidates"
fi
printf 'NAS_PUBLIC_HOSTNAME=%s\n' "${PUBLIC_HOST:-<unset>}"
printf 'NAS_LAN_IP=%s\n' "$LAN_IP"

section "Control channel (signaling)"
for host in "$LAN_IP" ${ICE_HOST:+"$ICE_HOST"}; do
  [ -n "$host" ] || continue
  probe_tcp "$host" "$SIGNAL_PORT" || true
done

section "Media port range (sample probes)"
printf 'Configured UDP/TCP media range: %s-%s\n' "$UDP_MIN" "$UDP_MAX"
printf 'Probing first/last ports in range (TCP handshake only)...\n'
for port in "$UDP_MIN" "$UDP_MAX"; do
  for host in "$LAN_IP" ${ICE_HOST:+"$ICE_HOST"}; do
    [ -n "$host" ] || continue
    probe_tcp "$host" "$port" || true
  done
done

section "Active session ports (container logs)"
if run_docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
  run_docker logs --tail=200 "$CONTAINER" 2>/dev/null | grep -E \
    'rewrote ICE host|ICE ports|ice-connection-state|peer-connection-state' || \
    warn "no recent ICE diagnostics in ${CONTAINER} logs — connect a browser first"
  active_ports="$(run_docker logs --tail=400 "$CONTAINER" 2>/dev/null | \
    sed -n 's/.*rewrote ICE host .* -> .* port \([0-9][0-9]*\).*/\1/p' | sort -u | tr '\n' ' ')"
  if [ -n "$active_ports" ]; then
    ok "recent ICE media ports from logs:${active_ports}"
    for port in $active_ports; do
      for host in "$LAN_IP" ${ICE_HOST:+"$ICE_HOST"}; do
        [ -n "$host" ] || continue
        probe_tcp "$host" "$port" || true
      done
    done
  else
    warn "no active ICE media port logged — open remote.html in a browser, then re-run"
  fi
else
  warn "container ${CONTAINER} not running"
fi

section "Host listeners"
if command -v ss >/dev/null 2>&1; then
  ss -lnt | grep -E ":(608[1-6]|6200[0-9]|6201[0-9]|62020)\b" || warn "expected WebRTC/noVNC TCP ports not listening"
  ss -lnu | grep -E ":(6200[0-9]|6201[0-9]|62020)\b" || warn "expected WebRTC UDP ports not listening"
elif command -v netstat >/dev/null 2>&1; then
  netstat -lnt | grep -E ":(608[1-6]|6200[0-9]|6201[0-9]|62020)\b" || warn "expected WebRTC/noVNC TCP ports not listening"
else
  warn "ss/netstat unavailable"
fi

section "Actionable checklist"
printf '%s\n' \
  "- Forward TCP 6081-6086 and UDP/TCP 62001-62040 to the NAS when using remote WebRTC." \
  "- Set WEBRTC_ICE_CANDIDATE_HOST to your public DDNS hostname for remote play." \
  "- Prefer Moonlight over Tailscale for production remote play (see docs/TAILSCALE.md)." \
  "- Use noVNC (vnc.html on 6081/6082) when WebRTC media ports are blocked upstream."

if [ "$WARN" -ne 0 ]; then
  printf '\nICE reachability check completed with warnings.\n'
  exit 1
fi
printf '\nICE reachability check passed.\n'
