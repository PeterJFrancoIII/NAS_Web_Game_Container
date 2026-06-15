#!/bin/sh
# Verify TURN on the NAS (run via ssh on MediaServer2).
set -eu

DOCKER_BIN="${RA2_DOCKER:-/usr/local/bin/docker}"
docker_cmd() {
  sudo "$DOCKER_BIN" "$@"
}
PLAYER="${PLAYER1_CONTAINER:-Cloud_Gaming_Player1}"
COTURN="${COTURN_CONTAINER:-RA2_Coturn}"
TURN_HOST="${WEBRTC_ICE_CANDIDATE_HOST:-peterjfrancoiii2.synology.me}"
TURN_PORT="${PLAYER1_WEBRTC_TURN_PORT:-62011}"
TURN_USER="${WEBRTC_TURN_USERNAME:-ra2turn}"
TURN_PASS="${WEBRTC_TURN_PASSWORD:-}"

echo "=== hello TURN iceServers ==="
docker_cmd exec "$PLAYER" python3 -u -c "
import asyncio, json, ssl, websockets
async def m():
 ctx=ssl.create_default_context();ctx.check_hostname=False;ctx.verify_mode=ssl.CERT_NONE
 async with websockets.connect('wss://127.0.0.1:6081/stream', ssl=ctx) as ws:
  h=json.loads(await ws.recv())
  for s in h.get('webrtcIceServers') or []:
   u=str(s.get('urls',''))
   if 'turn:' in u:
    print(u, 'user=', s.get('username'), 'cred=', 'yes' if s.get('credential') else 'no')
asyncio.run(m())
"

if [ -z "$TURN_PASS" ] && [ -f .env ]; then
  TURN_PASS="$(grep -E '^WEBRTC_TURN_PASSWORD=' .env | tail -n1 | cut -d= -f2- | tr -d '\r"'"'"'')"
fi

echo "=== turnutils static cred (localhost) ==="
docker_cmd exec "$COTURN" turnutils_uclient -v -y -p "$TURN_PORT" -u "$TURN_USER" -w "$TURN_PASS" -r ra2.lan.party 127.0.0.1 2>&1 | tail -6

echo "=== recent coturn auth lines ==="
docker_cmd logs "$COTURN" 2>&1 | grep -E "username=|ALLOC|relay addr|401" | tail -12
