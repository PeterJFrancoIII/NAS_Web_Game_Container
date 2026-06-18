#!/bin/sh
# Verify remote WebRTC TURN reachability from outside the LAN (run on Mac with VPN on).
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${RA2_ENV_FILE:-$PROJECT_DIR/.env}"

read_env() {
  key="$1"
  default="${2:-}"
  if [ -f "$ENV_FILE" ]; then
    val="$(grep -E "^${key}=" "$ENV_FILE" | tail -n1 | cut -d= -f2- | tr -d '\r"'"'"'')"
    if [ -n "$val" ]; then
      printf '%s\n' "$val"
      return 0
    fi
  fi
  printf '%s\n' "$default"
}

DDNS="$(read_env NAS_PUBLIC_HOSTNAME peterjfrancoiii2.synology.me)"
PLAY_PORT="$(read_env PLAYER1_HTTP_PORT 6081)"
TURN_PORT="$(read_env PLAYER1_WEBRTC_TURN_PORT 62011)"
TURNS_PORT="$(read_env WEBRTC_TURNS_PORT 5349)"
FAIL=0

check_tcp() {
  host="$1"
  port="$2"
  label="$3"
  if nc -z -w 3 "$host" "$port" 2>/dev/null; then
    echo "[remote-probe] OK   TCP $label ($host:$port)"
  else
    echo "[remote-probe] FAIL TCP $label ($host:$port)" >&2
    FAIL=1
  fi
}

check_udp() {
  host="$1"
  port="$2"
  label="$3"
  if nc -z -u -w 3 "$host" "$port" 2>/dev/null; then
    echo "[remote-probe] OK   UDP $label ($host:$port)"
  else
    echo "[remote-probe] WARN UDP $label ($host:$port) — may be blocked by client VPN/firewall" >&2
  fi
}

echo "=== remote WebRTC probe: $DDNS ==="

WAN_IP=""
if command -v dig >/dev/null 2>&1; then
  WAN_IP="$(dig +short "$DDNS" A 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)"
fi
if [ -n "$WAN_IP" ]; then
  echo "[remote-probe] DDNS resolves to $WAN_IP"
else
  echo "[remote-probe] WARN could not resolve $DDNS" >&2
fi

echo "=== turn-ice.json ==="
ICE_JSON="$(curl -fsSk "https://${DDNS}:${PLAY_PORT}/turn-ice.json" 2>/dev/null || true)"
if [ -n "$ICE_JSON" ]; then
  printf '%s\n' "$ICE_JSON" | head -c 4096
  echo ""
  echo "[remote-probe] OK   turn-ice.json"
else
  echo "[remote-probe] FAIL turn-ice.json (HTTPS ${DDNS}:${PLAY_PORT})" >&2
  FAIL=1
fi

echo "=== port reachability ==="
check_tcp "$DDNS" "$PLAY_PORT" "play HTTPS/WSS"
check_tcp "$DDNS" "$TURN_PORT" "TURN TCP"
check_udp "$DDNS" "$TURN_PORT" "TURN UDP"
# TURNS (5349) is non-fatal: gated off until a valid (non self-signed) cert is installed.
if nc -z -w 3 "$DDNS" "$TURNS_PORT" 2>/dev/null; then
  echo "[remote-probe] OK   TCP TURNS TLS ($DDNS:$TURNS_PORT)"
else
  echo "[remote-probe] WARN TURNS TLS ($DDNS:$TURNS_PORT) — optional (self-signed cert; TURN/TCP is the VPN fallback)"
fi

# Authoritative check: perform the real STUN/TURN Allocate handshake the browser
# would, using the exact credentials served in turn-ice.json. Proves relay works.
echo "=== TURN allocate (real relay handshake) ==="
if command -v python3 >/dev/null 2>&1 && [ -n "$ICE_JSON" ]; then
  ALLOC_TESTED=0
  ALLOC_OK=0
  TMP_ENTRIES="$(mktemp 2>/dev/null || printf '%s\n' "/tmp/turn-entries.$$")"
  printf '%s' "$ICE_JSON" | python3 -c '
import json, re, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for srv in data.get("iceServers", []):
    user = srv.get("username")
    cred = srv.get("credential")
    if not user or not cred:
        continue
    urls = srv.get("urls")
    urls = urls if isinstance(urls, list) else [urls]
    for url in urls:
        url = str(url)
        if not url.startswith("turn:"):
            continue
        m = re.match(r"turns?:([^:?]+):(\d+)", url)
        if not m:
            continue
        transport = "tcp" if "transport=tcp" in url else "udp"
        print(m.group(1), m.group(2), user, cred, transport)
' > "$TMP_ENTRIES" 2>/dev/null || true
  while IFS=' ' read -r H P U C T; do
    [ -n "$H" ] || continue
    ALLOC_TESTED=$((ALLOC_TESTED + 1))
    if python3 "$SCRIPT_DIR/turn_allocate_probe.py" "$H" "$P" "$U" "$C" "$T"; then
      ALLOC_OK=$((ALLOC_OK + 1))
    fi
  done < "$TMP_ENTRIES"
  rm -f "$TMP_ENTRIES"
  if [ "$ALLOC_TESTED" -gt 0 ] && [ "$ALLOC_OK" -eq 0 ]; then
    echo "[remote-probe] FAIL no TURN relay could be allocated ($ALLOC_TESTED tried) — relay path broken" >&2
    FAIL=1
  elif [ "$ALLOC_OK" -gt 0 ]; then
    echo "[remote-probe] OK   relay allocated on $ALLOC_OK/$ALLOC_TESTED transport(s)"
  fi
else
  echo "[remote-probe] WARN python3 or turn-ice.json unavailable — skipped real allocate test"
fi

if [ "$FAIL" -ne 0 ]; then
  echo "[remote-probe] FAILED — check router forwards to NAS (6081 TCP, 62011 UDP/TCP, 5349 TCP)" >&2
  exit 1
fi

echo "[remote-probe] ok"
