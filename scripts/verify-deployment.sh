#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

COMPOSE_DIR="${COMPOSE_DIR:-/volume2/Data/App_Development/ra2-lan-party/project}"
ENV_FILE="${ENV_FILE:-$COMPOSE_DIR/.env}"
PLAYER1="${PLAYER1:-ra2-player-1}"
PLAYER2="${PLAYER2:-ra2-player-2}"
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
if ! run_docker ps -a --filter name=ra2-player --format 'table {{.Names}}\t{{.Status}}'; then
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

note "noVNC HTTP"
for container in "$PLAYER1" "$PLAYER2"; do
  if exec_in "$container" 'python -c "import urllib.request; print(urllib.request.urlopen(\"http://127.0.0.1:6080/\", timeout=5).status)"' | grep -q '^200$'; then
    pass "$container noVNC returns HTTP 200"
  else
    fail "$container noVNC is not reachable on port 6080"
  fi
done

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
  printf '\nBrowser URLs:\n'
  printf '  Player 1: http://192.168.0.193:%s/vnc.html\n' "$port1"
  printf '  Player 2: http://192.168.0.193:%s/vnc.html\n' "$port2"
fi

if [ "$FAIL" -ne 0 ]; then
  printf '\nDeployment verification failed.\n'
  exit 1
fi

printf '\nDeployment verification passed.\n'
