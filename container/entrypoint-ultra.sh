#!/usr/bin/env bash
set -euo pipefail

ASSETS_DIR="${ASSETS_DIR:-/home/commander/game_assets}"
AOE2_ASSETS_DIR="${AOE2_ASSETS_DIR:-/home/commander/aoe2_assets}"
SC_ASSETS_DIR="${SC_ASSETS_DIR:-/home/commander/sc_assets}"
GAME_DIR="${WINEPREFIX:-/home/commander/.wine}/drive_c/RA2"
AOE2_DIR="${WINEPREFIX:-/home/commander/.wine}/drive_c/AOE2"
SC_DIR="${WINEPREFIX:-/home/commander/.wine}/drive_c/SC"
GAME_EXE="${GAME_EXE:-RA2MD.exe}"
PLAYER_ID="${PLAYER_ID:-unknown}"
PLAYER_SERIAL="${PLAYER_SERIAL:-}"
RESOLUTION="${RESOLUTION:-1024x768}"
RA2_DISPLAY_DEPTH="${RA2_DISPLAY_DEPTH:-16}"
WINE_ARCH="${WINEARCH:-win64}"
GAME_LAUNCHER_ENABLED="${GAME_LAUNCHER_ENABLED:-1}"
export RESOLUTION RA2_DISPLAY_DEPTH

ULTRA_DISPLAY_ENV="${ULTRA_DISPLAY_ENV:-/home/commander/.ra2/display.env}"
mkdir -p "$(dirname "$ULTRA_DISPLAY_ENV")"
printf 'RESOLUTION=%s\nRA2_DISPLAY_DEPTH=%s\n' "$RESOLUTION" "$RA2_DISPLAY_DEPTH" >"$ULTRA_DISPLAY_ENV"

log() {
  printf '[ra2-ultra-%s] %s\n' "$PLAYER_ID" "$*"
}

require_file() {
  if [ ! -f "$1" ]; then
    log "Missing required file: $1"
    exit 1
  fi
}

if [ -z "$PLAYER_SERIAL" ]; then
  log "PLAYER_SERIAL is required and must be unique per player."
  exit 1
fi

require_file "${ASSETS_DIR}/${GAME_EXE}"
require_file "${ASSETS_DIR}/ddraw.dll"
require_file "${ASSETS_DIR}/ddraw.ini"
require_file "${ASSETS_DIR}/wsock32.dll"

if ! grep -aq "cnc-ddraw" "${ASSETS_DIR}/ddraw.dll" 2>/dev/null; then
  log "ddraw.dll is not cnc-ddraw. Install with: sh scripts/install-cnc-ddraw.sh"
  exit 1
fi

if [ -f "${AOE2_ASSETS_DIR}/EMPIRES2.EXE" ]; then
  log "AOE2 assets detected at ${AOE2_ASSETS_DIR}"
else
  log "AOE2 assets not mounted (${AOE2_ASSETS_DIR}); launcher will offer RA2 only"
fi

if [ -f "${SC_ASSETS_DIR}/StarCraft.exe" ] && [ -f "${SC_ASSETS_DIR}/StarCraft.mpq" ] && [ -f "${SC_ASSETS_DIR}/BroodWar.mpq" ]; then
  log "StarCraft assets detected at ${SC_ASSETS_DIR}"
else
  log "StarCraft assets not mounted (${SC_ASSETS_DIR}); launcher will omit StarCraft"
fi

mkdir -p "${WINEPREFIX}"

XVFB_PID=""
cleanup() {
  if [ -n "$XVFB_PID" ] && kill -0 "$XVFB_PID" 2>/dev/null; then
    kill "$XVFB_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

start_setup_display() {
  Xvfb "${DISPLAY:-:1}" -screen 0 "${RESOLUTION}x${RA2_DISPLAY_DEPTH}" -nolisten tcp >/tmp/ra2-xvfb-init.log 2>&1 &
  XVFB_PID="$!"
  sleep 1
}

wine_prefix_ready() {
  [ -f "${WINEPREFIX}/drive_c/windows/system32/kernel32.dll" ] || return 1
  if [ "$WINE_ARCH" = "win32" ]; then
    [ ! -f "${WINEPREFIX}/drive_c/windows/syswow64/kernel32.dll" ]
  else
    [ -f "${WINEPREFIX}/drive_c/windows/syswow64/kernel32.dll" ]
  fi
}

link_game_assets() {
  target="$1"
  source="$2"
  if [ ! -d "$source" ] && [ ! -f "$source" ]; then
    return 0
  fi
  rm -rf "$target"
  ln -s "$source" "$target"
}

if [ ! -f "${WINEPREFIX}/.ra2_initialized" ] || ! wine_prefix_ready; then
  log "Initializing Wine prefix."
  start_setup_display
  if ! wine_prefix_ready; then
    export WINEDLLOVERRIDES="mscoree=d;mshtml=d;winegstreamer=;${WINEDLLOVERRIDES:-}"
    if ! timeout 300 wineboot --init; then
      log "wineboot --init failed or timed out."
      exit 1
    fi
    wineserver -k >/dev/null 2>&1 || true
  fi
  link_game_assets "$GAME_DIR" "$ASSETS_DIR"
  link_game_assets "$AOE2_DIR" "$AOE2_ASSETS_DIR"
  if [ -f "${SC_ASSETS_DIR}/StarCraft.exe" ] && [ -f "${SC_ASSETS_DIR}/StarCraft.mpq" ]; then
    link_game_assets "$SC_DIR" "$SC_ASSETS_DIR"
  fi
  touch "${WINEPREFIX}/.ra2_initialized"
elif [ -z "$XVFB_PID" ]; then
  start_setup_display
fi

link_game_assets "$GAME_DIR" "$ASSETS_DIR"
if [ -f "${AOE2_ASSETS_DIR}/EMPIRES2.EXE" ]; then
  link_game_assets "$AOE2_DIR" "$AOE2_ASSETS_DIR"
fi
if [ -f "${SC_ASSETS_DIR}/StarCraft.exe" ] && [ -f "${SC_ASSETS_DIR}/StarCraft.mpq" ]; then
  link_game_assets "$SC_DIR" "$SC_ASSETS_DIR"
fi

configure_serial() {
  key="$1"
  if ! wine reg add "$key" /v Serial /t REG_SZ /d "$PLAYER_SERIAL" /f >/dev/null 2>&1; then
    log "Warning: failed to set serial for $key"
  fi
}

clear_legacy_app_compat() {
  exe="$1"
  wine reg delete "HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\${exe}" /f >/dev/null 2>&1 || true
}

if wine_prefix_ready; then
  wine reg add "HKEY_CURRENT_USER\\Software\\Wine\\Drivers" /v Audio /t REG_SZ /d alsa /f >/dev/null 2>&1 || true
  wine reg add "HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows NT\\CurrentVersion\\AeDebug" /v Debugger /t REG_SZ /d "/bin/sh /opt/ra2/winedbg-minidump.sh %ld %ld" /f >/dev/null 2>&1 || true
  wine reg add "HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows NT\\CurrentVersion\\AeDebug" /v Auto /t REG_SZ /d 1 /f >/dev/null 2>&1 || true
  wine reg add "HKEY_CURRENT_USER\\Software\\Wine\\WineDbg" /v ShowCrashDialog /t REG_DWORD /d 0 /f >/dev/null 2>&1 || true
  clear_legacy_app_compat "RA2MD.exe"
  clear_legacy_app_compat "gamemd.exe"
  clear_legacy_app_compat "RA2.exe"
  clear_legacy_app_compat "game.exe"
  clear_legacy_app_compat "EMPIRES2.EXE"
  clear_legacy_app_compat "Brood War.exe"
  clear_legacy_app_compat "BROODWAR.EXE"
  clear_legacy_app_compat "StarCraft.exe"
  clear_legacy_app_compat "STARCRAFT.EXE"
  configure_serial "HKEY_LOCAL_MACHINE\\Software\\WOW6432Node\\Westwood\\Red Alert 2"
  configure_serial "HKEY_LOCAL_MACHINE\\Software\\Westwood\\Red Alert 2"
  configure_serial "HKEY_LOCAL_MACHINE\\Software\\WOW6432Node\\Westwood\\Yuri's Revenge"
  configure_serial "HKEY_LOCAL_MACHINE\\Software\\Westwood\\Yuri's Revenge"
  wineserver -k >/dev/null 2>&1 || true
fi

cleanup
trap - EXIT

for reg in system.reg user.reg userdef.reg .ra2_initialized .update-timestamp .aoe2_registered .starcraft_registered; do
  if [ -e "${WINEPREFIX}/${reg}" ]; then
    chmod u+rwX "${WINEPREFIX}/${reg}"
  fi
done

if [ "$GAME_LAUNCHER_ENABLED" = "1" ]; then
  log "Starting ultra stream gateway and game launcher."
else
  log "Starting ultra stream gateway and ${GAME_EXE}."
fi

# Locked Openbox only — ignore any user-local WM config that could expose a desktop shell.
rm -rf /home/commander/.config/openbox 2>/dev/null || true
rm -f /home/commander/.ra2/selected-game 2>/dev/null || true
/bin/sh /opt/ra2/game-session-state.sh waiting 2>/dev/null || true

exec supervisord -c /opt/ra2/supervisord.conf
