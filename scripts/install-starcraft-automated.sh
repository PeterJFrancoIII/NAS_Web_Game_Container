#!/bin/sh
# Automated StarCraft + Brood War install inside ra2-player-1 (best-effort xdotool).
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

GAMES_ROOT="${GAMES_ROOT:-/volume2/Data/Games}"
PACKED_DIR="${PACKED_DIR:-${GAMES_ROOT}/1 Packed - Compressed/StarCraft & Brood War}"
STAGE="${STAGE:-/tmp/sc_unpack_stage}"
PLAYER="${RA2_ULTRA_SERVICE:-ra2-player-1}"
CD_KEY="$(grep -Eo '[0-9]{10,}' "${PACKED_DIR}/CD Key.txt" 2>/dev/null | head -1 || true)"

log() { printf '[sc-auto] %s\n' "$*"; }

[ "$(container_status "$PLAYER")" = "running" ] || { log "${PLAYER} not running"; exit 1; }

SC_ISO="$(find "$PACKED_DIR" -maxdepth 1 -iname 'STARCRAFT.iso' | head -1)"
BW_ISO="$(find "$PACKED_DIR" -maxdepth 1 -iname 'BROODWAR.iso' | head -1)"
[ -n "$SC_ISO" ] && [ -n "$BW_ISO" ] || { log "ISOs missing"; exit 1; }

mkdir -p "$STAGE/sc_cd" "$STAGE/bw_cd"
7z x -y -o"$STAGE/sc_cd" "$SC_ISO" >/dev/null
7z x -y -o"$STAGE/bw_cd" "$BW_ISO" >/dev/null
run_docker cp "$STAGE/sc_cd/." "${PLAYER}:/tmp/sc_install_sc"
run_docker cp "$STAGE/bw_cd/." "${PLAYER}:/tmp/sc_install_bw"

run_setup() {
  label="$1"
  cd_dir="$2"
  check_exe="$3"
  log "installing ${label}..."
  run_docker exec -e DISPLAY=:1 -e SC_CD_KEY="${CD_KEY:-}" "$PLAYER" /bin/sh -c "
set -u
automate() {
  for _ in \$(seq 1 120); do
    wid=\$(xdotool search --name 'Starcraft Setup' 2>/dev/null | head -1 || true)
    if [ -n \"\$wid\" ]; then
      xdotool windowactivate --sync \"\$wid\" 2>/dev/null || true
      xdotool key --clearmodifiers Return 2>/dev/null || true
      sleep 1
      if [ -n \"\${SC_CD_KEY:-}\" ]; then
        xdotool type --delay 25 \"\${SC_CD_KEY}\" 2>/dev/null || true
        xdotool key Return 2>/dev/null || true
        sleep 1
      fi
      xdotool key alt+n Return 2>/dev/null || true
      sleep 1
      xdotool key alt+i Return 2>/dev/null || true
      sleep 1
      xdotool key Tab Return 2>/dev/null || true
    fi
    if find /home/commander/.wine/drive_c -iname '${check_exe}' 2>/dev/null | grep -q .; then
      return 0
    fi
    sleep 5
  done
  return 1
}

export WINEDLLOVERRIDES='mscoree=d;mshtml=d;comctl32=b'
wineserver -k >/dev/null 2>&1 || true
sleep 2
cd '${cd_dir}'
wine ./SETUP.EXE &
automate
wineserver -k >/dev/null 2>&1 || true
find /home/commander/.wine/drive_c -iname '${check_exe}' 2>/dev/null | head -1
"
}

result="$(run_setup "StarCraft base" "/tmp/sc_install_sc" "starcraft.exe")"
[ -n "$result" ] || { log "base install failed"; exit 1; }
log "base installed: $result"

result="$(run_setup "Brood War" "/tmp/sc_install_bw" "Brood War.exe")"
[ -n "$result" ] || result="$(run_setup "Brood War" "/tmp/sc_install_bw" "broodwar.exe")"
[ -n "$result" ] || { log "Brood War install failed"; exit 1; }
log "Brood War installed: $result"

/bin/sh "$SCRIPT_DIR/finalize-starcraft-install.sh"
