#!/usr/bin/env bash
set -euo pipefail

ASSETS_DIR="${ASSETS_DIR:-/home/commander/game_assets}"
GAME_DIR="${WINEPREFIX:-/home/commander/.wine}/drive_c/RA2"
GAME_EXE="${GAME_EXE:-RA2MD.exe}"
PLAYER_ID="${PLAYER_ID:-unknown}"
PLAYER_SERIAL="${PLAYER_SERIAL:-}"
RESOLUTION="${RESOLUTION:-1024x768}"
WINE_ARCH="${WINEARCH:-win64}"

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

mkdir -p "${WINEPREFIX}"

XVFB_PID=""
cleanup() {
  if [ -n "$XVFB_PID" ] && kill -0 "$XVFB_PID" 2>/dev/null; then
    kill "$XVFB_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

start_setup_display() {
  Xvfb "${DISPLAY:-:1}" -screen 0 "${RESOLUTION}x16" -nolisten tcp >/tmp/ra2-xvfb-init.log 2>&1 &
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
  rm -rf "$GAME_DIR"
  ln -s "$ASSETS_DIR" "$GAME_DIR"
  touch "${WINEPREFIX}/.ra2_initialized"
elif [ -z "$XVFB_PID" ]; then
  start_setup_display
fi

if [ ! -L "$GAME_DIR" ]; then
  rm -rf "$GAME_DIR"
  ln -s "$ASSETS_DIR" "$GAME_DIR"
fi

configure_serial() {
  key="$1"
  if ! wine reg add "$key" /v Serial /t REG_SZ /d "$PLAYER_SERIAL" /f >/dev/null 2>&1; then
    log "Warning: failed to set serial for $key"
  fi
}

configure_app_compat() {
  exe="$1"
  version="${RA2_WINE_APP_VERSION:-win98}"
  wine reg add "HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\${exe}" /v Version /t REG_SZ /d "$version" /f >/dev/null 2>&1 || \
    log "Warning: failed to set Wine version for $exe"
}

if wine_prefix_ready; then
  wine reg add "HKEY_CURRENT_USER\\Software\\Wine\\Drivers" /v Audio /t REG_SZ /d alsa /f >/dev/null 2>&1 || true
  wine reg add "HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows NT\\CurrentVersion\\AeDebug" /v Debugger /t REG_SZ /d "/bin/sh /opt/ra2/winedbg-minidump.sh %ld %ld" /f >/dev/null 2>&1 || true
  wine reg add "HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows NT\\CurrentVersion\\AeDebug" /v Auto /t REG_SZ /d 1 /f >/dev/null 2>&1 || true
  wine reg add "HKEY_CURRENT_USER\\Software\\Wine\\WineDbg" /v ShowCrashDialog /t REG_DWORD /d 0 /f >/dev/null 2>&1 || true
  configure_app_compat "RA2MD.exe"
  configure_app_compat "gamemd.exe"
  configure_app_compat "RA2.exe"
  configure_app_compat "game.exe"
  configure_serial "HKEY_LOCAL_MACHINE\\Software\\WOW6432Node\\Westwood\\Red Alert 2"
  configure_serial "HKEY_LOCAL_MACHINE\\Software\\Westwood\\Red Alert 2"
  configure_serial "HKEY_LOCAL_MACHINE\\Software\\WOW6432Node\\Westwood\\Yuri's Revenge"
  configure_serial "HKEY_LOCAL_MACHINE\\Software\\Westwood\\Yuri's Revenge"
  wineserver -k >/dev/null 2>&1 || true
fi

cleanup
trap - EXIT

for reg in system.reg user.reg userdef.reg .ra2_initialized .update-timestamp; do
  if [ -e "${WINEPREFIX}/${reg}" ]; then
    chmod u+rwX "${WINEPREFIX}/${reg}"
  fi
done

log "Starting ultra stream gateway and ${GAME_EXE}."
exec supervisord -c /opt/ra2/supervisord.conf
