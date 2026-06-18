#!/bin/sh
# Launch one game session and block until it exits cleanly.
# Called from start-game-ultra.sh after the launcher menu.

set -eu

GAME_ID="${1:?game id required}"
GAMES_MANIFEST="${GAMES_MANIFEST:-/opt/ra2/config/games.json}"

/bin/sh /opt/ra2/validate-game-id.sh "$GAME_ID" || {
  printf '[run-game] invalid game id: %s\n' "$GAME_ID" >&2
  exit 1
}

if [ ! -f "$GAMES_MANIFEST" ]; then
  printf '[run-game] missing manifest: %s\n' "$GAMES_MANIFEST" >&2
  exit 1
fi

lookup() {
  python3 - "$GAME_ID" "$GAMES_MANIFEST" <<'PY'
import json, shlex, sys
game_id, path = sys.argv[1], sys.argv[2]
profile = json.load(open(path, encoding="utf-8"))[game_id]
for key, value in profile.items():
    if isinstance(value, bool):
        value = "true" if value else "false"
    elif isinstance(value, list):
        value = " ".join(value)
    elif value is None:
        value = ""
    print(f"{key}={shlex.quote(str(value))}")
PY
}

while IFS= read -r line; do
  [ -n "$line" ] || continue
  eval "export $line"
done <<EOF
$(lookup)
EOF

ASSETS_DIR="$assetsPath"
case "${assetsEnv:-}" in
  AOE2_ASSETS_DIR)
    ASSETS_DIR="${AOE2_ASSETS_DIR:-$assetsPath}"
    ;;
  SC_ASSETS_DIR)
    ASSETS_DIR="${SC_ASSETS_DIR:-$assetsPath}"
    ;;
  ASSETS_DIR)
    ASSETS_DIR="${ASSETS_DIR:-$assetsPath}"
    ;;
esac

GAME_EXE="$gameExe"
GAME_PROCESS="$supervisedProcess"
export WINEDLLOVERRIDES="${dllOverrides:-mscoree=d;mshtml=d}"
if [ -n "${wineD3dConfig:-}" ]; then
  export WINE_D3D_CONFIG="$wineD3dConfig"
fi

DISPLAY_ENV="${ULTRA_DISPLAY_ENV:-/home/commander/.ra2/display.env}"
if [ -f "$DISPLAY_ENV" ]; then
  # shellcheck disable=SC1090
  . "$DISPLAY_ENV"
fi

READY_TIMEOUT="${ULTRA_GAME_READY_TIMEOUT:-90}"
DEFAULT_LOG_ROOT="${WINEPREFIX:-/home/commander/.wine}/ra2-crash-logs"
REQUESTED_LOG_ROOT="${ULTRA_GAME_LOG_ROOT:-/home/commander/ra2-logs-root}"
if grep -qs " ${REQUESTED_LOG_ROOT} " /proc/mounts 2>/dev/null; then
  LOG_ROOT="$REQUESTED_LOG_ROOT"
else
  LOG_ROOT="$DEFAULT_LOG_ROOT"
fi
DIAGNOSTIC_DIR="${ULTRA_GAME_DIAGNOSTIC_DIR:-${LOG_ROOT}/player${PLAYER_ID:-unknown}}"
WINE_LOG="${ULTRA_WINE_LOG:-${DIAGNOSTIC_DIR}/wine-current.log}"
WINE_DEBUG_CHANNELS="${ULTRA_WINEDEBUG:-err+all,+seh}"
GAME_OUTPUT_FILES="except.txt except_yr.txt ddraw.log cnc-ddraw.log debug.txt"
GAME_DIR="${ULTRA_GAME_WORK_DIR:-${DIAGNOSTIC_DIR}/game-work}"
STATE_DIR="${GAME_STATE_DIR:-/home/commander/.ra2}"
SELECTION_FILE="${GAME_SELECTION_FILE:-${STATE_DIR}/selected-game}"
SWITCH_REQUESTED=0

read_selection_file() {
  if [ ! -f "$SELECTION_FILE" ]; then
    return 1
  fi
  tr -d ' \t\r\n' <"$SELECTION_FILE"
}

request_game_switch() {
  switch_to="$1"
  log "switch requested: ${GAME_ID} -> ${switch_to}"
  SWITCH_REQUESTED=1
  /bin/sh /opt/ra2/game-session-state.sh switching "$switch_to"
  stop_wine
  wait "$wine_pid" 2>/dev/null || true
  exit 0
}

finish_session() {
  if [ "$SWITCH_REQUESTED" = "1" ]; then
    return 0
  fi
  /bin/sh /opt/ra2/game-session-state.sh waiting
  rm -f "$SELECTION_FILE"
}

if [ -n "${RA2_GAME_CPUSET:-}" ]; then
  GAME_CPUSET="$RA2_GAME_CPUSET"
elif printf '%s' "${PLAYER_ID:-}" | grep -Eq '^[0-9]+$' && [ "${PLAYER_ID:-0}" -gt 0 ]; then
  GAME_CPUSET="$((${PLAYER_ID} - 1))"
else
  GAME_CPUSET="0"
fi

log() {
  printf '[run-game:%s] %s\n' "$GAME_ID" "$*"
}

maybe_switch_game_display() {
  [ -x /opt/ra2/switch-game-display.sh ] || return 0
  gw="${gameWidth:-1024}"
  gh="${gameHeight:-768}"
  log "requesting stream display ${gw}x${gh} for ${GAME_ID}"
  if ! /bin/sh /opt/ra2/switch-game-display.sh "${gw}x${gh}"; then
    log "warning: display switch to ${gw}x${gh} failed"
    return 0
  fi
  if [ -f "$DISPLAY_ENV" ]; then
    # shellcheck disable=SC1090
    . "$DISPLAY_ENV"
  fi
}

sync_game_resolution_args() {
  [ "$GAME_ID" = "aoe2" ] || return 0
  width="${gameWidth:-800}"
  wineArgs="NoStartup ${width}"
  log "AoE II launch resolution ${width}x${gameHeight:-600}"
}

maybe_switch_game_display
sync_game_resolution_args

live_game_count() {
  ps -eo stat=,comm= 2>/dev/null | awk -v name="$GAME_PROCESS" 'tolower($2) == tolower(name) && $1 !~ /^Z/ { count++ } END { print count + 0 }'
}

zombie_game_count() {
  ps -eo stat=,comm= 2>/dev/null | awk -v name="$GAME_PROCESS" 'tolower($2) == tolower(name) && $1 ~ /^Z/ { count++ } END { print count + 0 }'
}

pin_game_affinity() {
  if ! command -v taskset >/dev/null 2>&1 || [ -z "$GAME_CPUSET" ]; then
    return 0
  fi
  ps -eo pid=,comm= 2>/dev/null | awk -v name="$GAME_PROCESS" 'tolower($2) == tolower(name) { print $1 }' | while read -r pid; do
    [ -n "$pid" ] || continue
    taskset -pc "$GAME_CPUSET" "$pid" >/dev/null 2>&1 || true
  done
}

stop_wine() {
  wineserver -k >/dev/null 2>&1 || true
}

apply_language_overlay() {
  lang_dir="${languageDir:-}"
  [ -n "$lang_dir" ] || return 0
  if [ ! -d "$lang_dir" ]; then
    log "warning: language dir missing at ${lang_dir}; using asset locale"
    return 0
  fi
  dll=""
  for name in LANGUAGE.DLL language.dll Language.dll; do
    if [ -f "$lang_dir/$name" ]; then
      dll="$lang_dir/$name"
      break
    fi
  done
  if [ -n "$dll" ]; then
    cp -f "$dll" "$GAME_DIR/LANGUAGE.DLL"
    log "applied language overlay from ${dll}"
  else
    for name in LANGUAGE.DLL language.dll Language.dll; do
      if [ -f "$ASSETS_DIR/$name" ]; then
        cp -f "$ASSETS_DIR/$name" "$GAME_DIR/LANGUAGE.DLL"
        log "using LANGUAGE.DLL from game assets (${ASSETS_DIR}/${name})"
        dll="$ASSETS_DIR/$name"
        break
      fi
    done
    if [ -z "$dll" ]; then
      log "warning: no LANGUAGE.DLL in ${lang_dir} or assets; run scripts/install-aoe2-english-language.sh"
    fi
  fi
  if [ -d "$lang_dir/History" ]; then
    rm -rf "$GAME_DIR/History" 2>/dev/null || true
    cp -a "$lang_dir/History" "$GAME_DIR/History"
  fi
}

prepare_game_work_dir() {
  if [ "${writableWorkDir:-}" = "true" ]; then
    GAME_DIR="${DIAGNOSTIC_DIR}/game-work-${GAME_ID}"
    mkdir -p "$GAME_DIR" 2>/dev/null || {
      log "cannot create writable work dir; falling back to assets"
      GAME_DIR="$ASSETS_DIR"
      return
    }
    find "$GAME_DIR" -maxdepth 1 \( -type l -o -type f \( -name 'ddraw.dll' -o -name 'ddraw.ini' -o -name 'LANGUAGE.DLL' \) \) -exec rm -f {} + 2>/dev/null || true
    rm -rf "$GAME_DIR/History" 2>/dev/null || true
    for path in "$ASSETS_DIR"/* "$ASSETS_DIR"/.[!.]* "$ASSETS_DIR"/..?*; do
      [ -e "$path" ] || continue
      base="$(basename "$path")"
      case " ${GAME_OUTPUT_FILES} " in
        *" ${base} "*) continue ;;
      esac
      case "$base" in
        ddraw.dll|ddraw.ini|AVI|LANGUAGE.DLL|language.dll|Language.dll|History) continue ;;
      esac
      [ -e "$GAME_DIR/$base" ] || ln -sf "$path" "$GAME_DIR/$base" 2>/dev/null || true
    done
    use_cnc_ddraw="${useCncDdraw:-true}"
    if [ "$use_cnc_ddraw" != "false" ]; then
      ra2_ddraw="/home/commander/game_assets/ddraw.dll"
      if [ -f "$ra2_ddraw" ]; then
        cp -f "$ra2_ddraw" "$GAME_DIR/ddraw.dll"
      else
        log "warning: RA2 cnc-ddraw missing at ${ra2_ddraw}; DirectDraw may fail"
      fi
      ddraw_ini_src="${ddrawIni:-/opt/ra2/config/aoe2-ddraw.ini}"
      if [ -f "$ddraw_ini_src" ]; then
        cp -f "$ddraw_ini_src" "$GAME_DIR/ddraw.ini"
      else
        log "warning: ${ddraw_ini_src} missing"
      fi
    fi
    mkdir -p "$GAME_DIR/AVI"
    apply_language_overlay
    return
  fi
  if [ "$syncTransport" != "true" ]; then
    GAME_DIR="$ASSETS_DIR"
    return
  fi
  mkdir -p "$GAME_DIR" 2>/dev/null || {
    GAME_DIR="$ASSETS_DIR"
    return
  }
  find "$GAME_DIR" -maxdepth 1 -type l -exec rm -f {} + 2>/dev/null || true
  for path in "$ASSETS_DIR"/* "$ASSETS_DIR"/.[!.]* "$ASSETS_DIR"/..?*; do
    [ -e "$path" ] || continue
    base="$(basename "$path")"
    case " ${GAME_OUTPUT_FILES} " in
      *" ${base} "*) continue ;;
    esac
    case "$base" in
      RA2.ini|RA2MD.ini|ra2.ini|ra2md.ini|ddraw.ini) continue ;;
    esac
    [ -e "$GAME_DIR/$base" ] || ln -s "$path" "$GAME_DIR/$base" 2>/dev/null || true
  done
}

maybe_run_game_setup() {
  [ -n "${setupExe:-}" ] || return 0
  marker="${WINEPREFIX:-/home/commander/.wine}/.${GAME_ID}_registered"
  setup_path="${ASSETS_DIR}/${setupExe}"
  if [ -f "$marker" ] || [ ! -f "$setup_path" ]; then
    return 0
  fi
  log "running one-time ${setupExe}"
  WINEDEBUG=-all /opt/wine/bin/wine "$setup_path" >>"$WINE_LOG" 2>&1 || log "warning: ${setupExe} returned non-zero"
  touch "$marker"
  wineserver -k >/dev/null 2>&1 || true
}

if [ ! -f "${ASSETS_DIR}/${GAME_EXE}" ]; then
  log "missing executable: ${ASSETS_DIR}/${GAME_EXE}"
  rm -f "$SELECTION_FILE" 2>/dev/null || true
  /bin/sh /opt/ra2/game-session-state.sh waiting 2>/dev/null || true
  exit 1
fi

mkdir -p "$DIAGNOSTIC_DIR" 2>/dev/null || true
prepare_game_work_dir

if [ "$GAME_ID" = "starcraft" ] && [ -x /opt/ra2/prepare-starcraft-session.sh ]; then
  /bin/sh /opt/ra2/prepare-starcraft-session.sh "$GAME_DIR" || {
    log "StarCraft work-dir preparation failed"
    exit 1
  }
fi

if [ "$GAME_ID" = "aoe2" ] && [ -x /opt/ra2/prepare-aoe2-session.sh ]; then
  /bin/sh /opt/ra2/prepare-aoe2-session.sh "$GAME_DIR" || {
    log "AoE II work-dir preparation failed"
    exit 1
  }
fi

if [ "$syncTransport" = "true" ] && [ -x /opt/ra2/sync-game-transport.sh ]; then
  width="${RESOLUTION%x*}"
  height="${RESOLUTION#*x}"
  fps="${ULTRA_VIDEO_FPS:-24}"
  /bin/sh /opt/ra2/sync-game-transport.sh "$fps" "$width" "$height" || log "transport sync skipped"
fi

if [ "$ensureIniLinks" = "true" ] && [ -x /opt/ra2/ensure-game-ini-links.sh ]; then
  /bin/sh /opt/ra2/ensure-game-ini-links.sh || log "ini link ensure skipped"
fi

maybe_run_game_setup

WINE_LAUNCH_CWD="$GAME_DIR"
if [ -n "${wineLaunchCwdEnv:-}" ]; then
  case "$wineLaunchCwdEnv" in
    AOE2_ASSETS_DIR)
      WINE_LAUNCH_CWD="${AOE2_ASSETS_DIR:-$assetsPath}"
      ;;
    SC_ASSETS_DIR)
      WINE_LAUNCH_CWD="${SC_ASSETS_DIR:-$assetsPath}"
      ;;
    ASSETS_DIR)
      WINE_LAUNCH_CWD="${ASSETS_DIR:-$assetsPath}"
      ;;
    *)
      log "warning: unknown wineLaunchCwdEnv=${wineLaunchCwdEnv}; using game work dir"
      ;;
  esac
fi
cd "$WINE_LAUNCH_CWD"

/bin/sh /opt/ra2/game-session-state.sh running "$GAME_ID"
printf '%s\n' "$GAME_ID" >"$SELECTION_FILE"
chmod 600 "$SELECTION_FILE" 2>/dev/null || true

log "starting ${title} (${GAME_EXE}); supervising ${GAME_PROCESS}"
if [ -n "${gameLocale:-}" ]; then
  export LANG="$gameLocale"
  export LC_ALL="$gameLocale"
fi
if [ -f "$WINE_LOG" ]; then
  cp "$WINE_LOG" "${DIAGNOSTIC_DIR}/wine-previous.log" 2>/dev/null || true
fi
{
  printf '[run-game] wine launch at %s game=%s exe=%s\n' "$(date -Iseconds 2>/dev/null || date)" "$GAME_ID" "$GAME_EXE"
} >"$WINE_LOG" 2>/dev/null || true

set -- /opt/wine/bin/wine "${wineExePath:-${GAME_DIR}/${GAME_EXE}}"
if [ -n "${wineArgs:-}" ]; then
  # shellcheck disable=SC2086
  set -- "$@" $wineArgs
fi

if command -v taskset >/dev/null 2>&1 && [ -n "$GAME_CPUSET" ]; then
  WINEDEBUG="$WINE_DEBUG_CHANNELS" taskset -c "$GAME_CPUSET" "$@" >>"$WINE_LOG" 2>&1 &
else
  WINEDEBUG="$WINE_DEBUG_CHANNELS" "$@" >>"$WINE_LOG" 2>&1 &
fi
wine_pid="$!"

started_at="$(date +%s)"
seen_game=0

while true; do
  switch_to="$(read_selection_file 2>/dev/null || true)"
  if [ -n "$switch_to" ] && [ "$switch_to" != "$GAME_ID" ]; then
    request_game_switch "$switch_to"
  fi

  if [ "$(zombie_game_count)" -gt 0 ]; then
    log "${GAME_PROCESS} is defunct; ending session"
    stop_wine
    wait "$wine_pid" 2>/dev/null || true
    finish_session
    exit 0
  fi

  game_live="$(live_game_count)"
  wine_live=0
  if kill -0 "$wine_pid" 2>/dev/null; then
    wine_live=1
  fi

  if [ "$game_live" -gt 0 ]; then
    seen_game=1
    pin_game_affinity
  elif [ "$seen_game" = "1" ]; then
    log "${GAME_PROCESS} exited; returning to launcher"
    stop_wine
    wait "$wine_pid" 2>/dev/null || true
    finish_session
    exit 0
  elif [ "$wine_live" -eq 0 ]; then
    set +e
    wait "$wine_pid" 2>/dev/null
    status="$?"
    set -e
    log "wine exited with status ${status} before ${GAME_PROCESS} was ready"
    stop_wine
    finish_session
    exit 0
  elif [ "$(($(date +%s) - started_at))" -gt "$READY_TIMEOUT" ]; then
    log "${GAME_PROCESS} did not become ready within ${READY_TIMEOUT}s"
    stop_wine
    wait "$wine_pid" 2>/dev/null || true
    finish_session
    exit 0
  fi

  sleep 1
done
