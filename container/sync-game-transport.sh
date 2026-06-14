#!/bin/sh
# Lock in-game render rate and resolution configs to the active transport/display tier.
set -eu

VIDEO_FPS="${1:-24}"
DISPLAY_WIDTH="${2:-1024}"
DISPLAY_HEIGHT="${3:-768}"
GAME_MAX_FPS="${ULTRA_GAME_MAX_FPS:-24}"
GAME_MAX_TICKS="${ULTRA_GAME_MAX_TICKS:-0}"

LOG_ROOT="${ULTRA_GAME_LOG_ROOT:-/home/commander/ra2-logs-root}"
DIAGNOSTIC_DIR="${ULTRA_GAME_DIAGNOSTIC_DIR:-${LOG_ROOT}/player${PLAYER_ID:-unknown}}"
GAME_WORK="${ULTRA_GAME_WORK_DIR:-${DIAGNOSTIC_DIR}/game-work}"
ASSETS_DIR="${ASSETS_DIR:-/home/commander/game_assets}"

log() {
  printf '[ultra-sync] %s\n' "$*" >&2
}

if pgrep -f "${ULTRA_GAME_PROCESS:-gamemd.exe}" >/dev/null 2>&1; then
  log "gamemd is running; refusing to rewrite game-work configs"
  exit 0
fi

patch_ini_value() {
  file="$1"
  section="$2"
  key="$3"
  value="$4"
  [ -f "$file" ] || return 0
  awk -v section="$section" -v key="$key" -v value="$value" '
    BEGIN { in_section = 0 }
    /^\[/ {
      in_section = ($0 == "[" section "]")
    }
    in_section && $0 ~ "^" key "=" {
      print key "=" value
      next
    }
    { print }
  ' "$file" >"${file}.tmp" && mv "${file}.tmp" "$file"
}

patch_ddraw() {
  file="$1"
  [ -f "$file" ] || return 0
  awk -v width="$DISPLAY_WIDTH" -v height="$DISPLAY_HEIGHT" -v fps="$GAME_MAX_FPS" -v ticks="$GAME_MAX_TICKS" '
    BEGIN { seen_devmode = 0; seen_maxgameticks = 0; seen_minfps = 0 }
    /^width=/ { print "width=" width; next }
    /^height=/ { print "height=" height; next }
    /^maxfps=/ { print "maxfps=" fps; next }
    /^vsync=/ { print "vsync=false"; next }
    /^maxgameticks=/ { print "maxgameticks=" ticks; seen_maxgameticks = 1; next }
    /^minfps=/ { print "minfps=-1"; seen_minfps = 1; next }
    /^singlecpu=/ { next }
    /^handlemouse=/ { next }
    /^devmode=/ { print "devmode=false"; seen_devmode = 1; next }
    { print }
    END {
      if (!seen_devmode) print "devmode=false"
      if (!seen_maxgameticks) print "maxgameticks=" ticks
      if (!seen_minfps) print "minfps=-1"
    }
  ' "$file" >"${file}.tmp" && mv "${file}.tmp" "$file"
}

materialize_config() {
  name="$1"
  if [ -f "${ASSETS_DIR}/${name}" ]; then
    mkdir -p "$GAME_WORK"
    cp -f "${ASSETS_DIR}/${name}" "${GAME_WORK}/${name}"
  fi
}

link_ini_alias() {
  canonical="$1"
  alias="$2"
  [ -f "${GAME_WORK}/${canonical}" ] || return 0
  rm -f "${GAME_WORK}/${alias}"
  ln -sf "$canonical" "${GAME_WORK}/${alias}"
}

mkdir -p "$GAME_WORK"
# Linux is case-sensitive; stale lowercase ra2.ini from Windows saves can shadow
# the patched RA2.ini/RA2MD.ini and break map load (missing AllowHiResModes).
rm -f "${GAME_WORK}/ra2.ini" "${GAME_WORK}/ra2md.ini"
for name in RA2.ini RA2MD.ini ddraw.ini; do
  materialize_config "$name"
done

for ini in RA2.ini RA2MD.ini; do
  patch_ini_value "${GAME_WORK}/${ini}" "Video" "AllowHiResModes" "yes"
  patch_ini_value "${GAME_WORK}/${ini}" "Video" "VideoBackBuffer" "no"
  patch_ini_value "${GAME_WORK}/${ini}" "Video" "ScreenWidth" "$DISPLAY_WIDTH"
  patch_ini_value "${GAME_WORK}/${ini}" "Video" "ScreenHeight" "$DISPLAY_HEIGHT"
done
patch_ddraw "${GAME_WORK}/ddraw.ini"
(
  cd "$GAME_WORK"
  link_ini_alias RA2MD.ini ra2md.ini
  link_ini_alias RA2MD.ini ra2.ini
)

if [ -x /opt/ra2/ensure-game-ini-links.sh ]; then
  /bin/sh /opt/ra2/ensure-game-ini-links.sh || true
fi

log "synced game-work to ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT} game_maxfps=${GAME_MAX_FPS} game_maxticks=${GAME_MAX_TICKS} stream_fps=${VIDEO_FPS} (vsync off)"
