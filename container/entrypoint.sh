#!/usr/bin/env bash
set -euo pipefail

ASSETS_DIR="${ASSETS_DIR:-/home/commander/game_assets}"
GAME_DIR="${WINEPREFIX:-/home/commander/.wine}/drive_c/RA2"
GAME_EXE="${GAME_EXE:-RA2MD.exe}"
PLAYER_ID="${PLAYER_ID:-unknown}"
PLAYER_SERIAL="${PLAYER_SERIAL:-}"
VNC_PASSWORD="${VNC_PASSWORD:-}"
RESOLUTION="${RESOLUTION:-1024x768}"

log() {
  printf '[ra2-player-%s] %s\n' "$PLAYER_ID" "$*"
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

if [ -z "$VNC_PASSWORD" ]; then
  log "VNC_PASSWORD is required."
  exit 1
fi

require_file "${ASSETS_DIR}/${GAME_EXE}"
require_file "${ASSETS_DIR}/ddraw.dll"
require_file "${ASSETS_DIR}/ddraw.ini"
require_file "${ASSETS_DIR}/wsock32.dll"

require_cnc_ddraw() {
  if ! grep -aq "cnc-ddraw" "${ASSETS_DIR}/ddraw.dll" 2>/dev/null; then
    log "ddraw.dll is not cnc-ddraw. RA2 will fail with \"Unable to set the video mode\"."
    log "Install the correct wrapper with: sh scripts/install-cnc-ddraw.sh"
    exit 1
  fi
}

require_cnc_ddraw

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
  [ -f "${WINEPREFIX}/drive_c/windows/system32/kernel32.dll" ] && \
    [ -f "${WINEPREFIX}/drive_c/windows/syswow64/kernel32.dll" ]
}

if [ ! -f "${WINEPREFIX}/.ra2_initialized" ] || ! wine_prefix_ready; then
  log "Initializing Wine prefix."
  log "Using $(wine --version 2>/dev/null || echo unknown-wine)."
  start_setup_display
  if ! wine_prefix_ready; then
    log "Running wineboot to create Windows system files."
    export WINEDLLOVERRIDES="mscoree=d;mshtml=d;winegstreamer=;${WINEDLLOVERRIDES:-}"
    if ! timeout 300 wineboot --init; then
      log "wineboot --init failed or timed out."
      exit 1
    fi
    wineserver -k >/dev/null 2>&1 || true
  fi
  if ! wine_prefix_ready; then
    log "Wine prefix is missing Windows system files."
    exit 1
  fi
  log "Wine prefix verified."
  wineserver -k >/dev/null 2>&1 || true
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
  label="$2"

  if ! wine reg add "$key" /v Serial /t REG_SZ /d "$PLAYER_SERIAL" /f >/dev/null 2>&1; then
    log "Warning: failed to set multiplayer serial for ${label}."
  fi
}

log "Configuring Wine registry for PulseAudio ALSA output and unique multiplayer serial."
if wine_prefix_ready; then
  if ! wine reg add "HKEY_CURRENT_USER\\Software\\Wine\\Drivers" /v Audio /t REG_SZ /d alsa /f >/dev/null 2>&1; then
    log "Warning: failed to set Wine audio driver."
  fi
  configure_serial "HKEY_LOCAL_MACHINE\\Software\\WOW6432Node\\Westwood\\Red Alert 2" "Red Alert 2 WOW6432Node"
  configure_serial "HKEY_LOCAL_MACHINE\\Software\\Westwood\\Red Alert 2" "Red Alert 2"
  configure_serial "HKEY_LOCAL_MACHINE\\Software\\WOW6432Node\\Westwood\\Yuri's Revenge" "Yuri's Revenge WOW6432Node"
  configure_serial "HKEY_LOCAL_MACHINE\\Software\\Westwood\\Yuri's Revenge" "Yuri's Revenge"
  wineserver -k >/dev/null 2>&1 || true
else
  log "Warning: Wine prefix is not ready; skipping registry configuration."
fi

cleanup
trap - EXIT

# Only touch writable Wine metadata. C:\RA2 is a symlink to read-only game assets.
for reg in system.reg user.reg userdef.reg .ra2_initialized .update-timestamp; do
  if [ -e "${WINEPREFIX}/${reg}" ]; then
    chmod u+rwX "${WINEPREFIX}/${reg}"
  fi
done
if [ -d "${WINEPREFIX}/dosdevices" ]; then
  chmod -R u+rwX "${WINEPREFIX}/dosdevices"
fi

umask 077
x11vnc -storepasswd "$VNC_PASSWORD" /tmp/x11vnc.pass >/dev/null

if [ -f /opt/ra2/patch-novnc.sh ]; then
  log "Applying noVNC audio/video sync tuning."
  /bin/bash /opt/ra2/patch-novnc.sh /opt/novnc
fi

if [ -f /opt/ra2/remote/remote.html ]; then
  ln -sf /opt/ra2/remote/remote.html /opt/novnc/remote.html
  ln -sf /opt/ra2/remote/remote-play.js /opt/novnc/remote-play.js
fi

log "Starting noVNC display stack and ${GAME_EXE}."
exec supervisord -c /opt/ra2/supervisord.conf
