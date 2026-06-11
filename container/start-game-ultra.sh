#!/bin/sh
set -eu

GAME_EXE="${GAME_EXE:-RA2MD.exe}"
ASSETS_DIR="${ASSETS_DIR:-/home/commander/game_assets}"
GAME_PROCESS="${ULTRA_GAME_PROCESS:-gamemd.exe}"
READY_TIMEOUT="${ULTRA_GAME_READY_TIMEOUT:-90}"
DEFAULT_LOG_ROOT="${WINEPREFIX:-/home/commander/.wine}/ra2-crash-logs"
REQUESTED_LOG_ROOT="${ULTRA_GAME_LOG_ROOT:-/home/commander/ra2-logs-root}"
if grep -qs " ${REQUESTED_LOG_ROOT} " /proc/mounts 2>/dev/null; then
  LOG_ROOT="$REQUESTED_LOG_ROOT"
else
  LOG_ROOT="$DEFAULT_LOG_ROOT"
fi
DIAGNOSTIC_DIR="${ULTRA_GAME_DIAGNOSTIC_DIR:-${LOG_ROOT}/player${PLAYER_ID:-unknown}}"
INPUT_TRACE="${ULTRA_INPUT_TRACE:-${DIAGNOSTIC_DIR}/input-events.log}"
GATEWAY_LOG="${ULTRA_GATEWAY_LOG:-${DIAGNOSTIC_DIR}/gateway.log}"
WINE_LOG="${ULTRA_WINE_LOG:-${DIAGNOSTIC_DIR}/wine-current.log}"
WINE_DEBUG_CHANNELS="${ULTRA_WINEDEBUG:-err+all,+seh}"
GAME_DIR="${ULTRA_GAME_WORK_DIR:-${DIAGNOSTIC_DIR}/game-work}"
GAME_OUTPUT_FILES="except.txt except_yr.txt ddraw.log cnc-ddraw.log debug.txt"
if [ -n "${RA2_GAME_CPUSET:-}" ]; then
  GAME_CPUSET="$RA2_GAME_CPUSET"
elif printf '%s' "${PLAYER_ID:-}" | grep -Eq '^[0-9]+$' && [ "${PLAYER_ID:-0}" -gt 0 ]; then
  GAME_CPUSET="$((${PLAYER_ID} - 1))"
else
  GAME_CPUSET="0"
fi

mkdir -p "$DIAGNOSTIC_DIR" 2>/dev/null || true

log() {
  printf '[ultra-game] %s\n' "$*"
}

live_game_count() {
  ps -eo stat=,comm= 2>/dev/null | awk -v name="$GAME_PROCESS" '$2 == name && $1 !~ /^Z/ { count++ } END { print count + 0 }'
}

zombie_game_count() {
  ps -eo stat=,comm= 2>/dev/null | awk -v name="$GAME_PROCESS" '$2 == name && $1 ~ /^Z/ { count++ } END { print count + 0 }'
}

pin_game_affinity() {
  if ! command -v taskset >/dev/null 2>&1 || [ -z "$GAME_CPUSET" ]; then
    return 0
  fi
  ps -eo pid=,comm= 2>/dev/null | awk -v name="$GAME_PROCESS" '$2 == name { print $1 }' | while read -r pid; do
    [ -n "$pid" ] || continue
    taskset -pc "$GAME_CPUSET" "$pid" >/dev/null 2>&1 || true
  done
}

stop_wine() {
  wineserver -k >/dev/null 2>&1 || true
}

dump_file_tail() {
  label="$1"
  path="$2"
  lines="${3:-120}"
  printf '\n[ultra-game] --- %s: %s ---\n' "$label" "$path"
  if [ -f "$path" ]; then
    tail -n "$lines" "$path" 2>/dev/null || true
  else
    printf '[ultra-game] missing: %s\n' "$path"
  fi
}

prepare_game_work_dir() {
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
    [ -e "$GAME_DIR/$base" ] || ln -s "$path" "$GAME_DIR/$base" 2>/dev/null || true
  done
}

dump_lockup_report() {
  reason="$1"
  mkdir -p "$DIAGNOSTIC_DIR" 2>/dev/null || true
  stamp="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%s)"
  safe_reason="$(printf '%s' "$reason" | tr -c 'A-Za-z0-9_.-' '_')"
  report="${DIAGNOSTIC_DIR}/crash-${stamp}-${safe_reason}.log"
  {
    printf '[ultra-game] crash report reason=%s at %s\n' "$reason" "$(date -Iseconds 2>/dev/null || date)"
    printf '[ultra-game] report=%s\n' "$report"
    printf '[ultra-game] supervised exe=%s process=%s wine_pid=%s seen_game=%s\n' "$GAME_EXE" "$GAME_PROCESS" "${wine_pid:-unknown}" "${seen_game:-0}"
    printf '[ultra-game] player=%s display=%s wineprefix=%s assets=%s game_dir=%s cpuset=%s log_root=%s requested_log_root=%s\n' "${PLAYER_ID:-unknown}" "${DISPLAY:-unknown}" "${WINEPREFIX:-/home/commander/.wine}" "$ASSETS_DIR" "$GAME_DIR" "$GAME_CPUSET" "$LOG_ROOT" "$REQUESTED_LOG_ROOT"
    printf '[ultra-game] host_log_hint=%s/player%s\n' "${ULTRA_GAME_HOST_LOG_DIR:-/volume2/Data/App_Development/ra2-lan-party/logs}" "${PLAYER_ID:-unknown}"
    printf '[ultra-game] fallback_host_log_hint=/volume2/Data/App_Development/ra2-lan-party/prefixes/player%s/ra2-crash-logs/player%s\n' "${PLAYER_ID:-unknown}" "${PLAYER_ID:-unknown}"
    printf '[ultra-game] uptime: '
    cat /proc/uptime 2>/dev/null || true
    printf '[ultra-game] kernel: '
    uname -a 2>/dev/null || true
    printf '[ultra-game] memory:\n'
    free -m 2>/dev/null || sed -n '1,12p' /proc/meminfo 2>/dev/null || true
    printf '[ultra-game] disk:\n'
    df -h "$DIAGNOSTIC_DIR" /tmp "$ASSETS_DIR" "$GAME_DIR" 2>/dev/null || true
    printf '[ultra-game] matching processes:\n'
    ps -eo pid=,ppid=,stat=,etime=,rss=,comm=,args= 2>/dev/null \
      | awk 'tolower($0) ~ /gamemd|ra2md|wine|wineserver|explorer|services|plugplay|start-game-ultra/ { print }' || true
    if [ -n "${wine_pid:-}" ] && [ -r "/proc/${wine_pid}/status" ]; then
      printf '\n[ultra-game] wine process status:\n'
      cat "/proc/${wine_pid}/status" 2>/dev/null || true
    fi
    printf '\n[ultra-game] active X window:\n'
    xdotool getactivewindow getwindowname 2>/dev/null || true
    printf '[ultra-game] recent game work logs:\n'
    find "$GAME_DIR" -maxdepth 1 -type f \( -iname "*.log" -o -iname "except*.txt" -o -iname "debug*.txt" \) \
      -printf "%TY-%Tm-%Td %TH:%TM:%TS %s %p\n" 2>/dev/null | sort | tail -n 20 || true
    printf '[ultra-game] recent Wine minidumps:\n'
    find "$DIAGNOSTIC_DIR" -maxdepth 1 -type f \( -iname "*.mdmp" -o -iname "winedbg-minidump-*.log" \) \
      -printf "%TY-%Tm-%Td %TH:%TM:%TS %s %p\n" 2>/dev/null | sort | tail -n 20 || true
    dump_file_tail "gateway lifecycle log" "$GATEWAY_LOG" 200
    dump_file_tail "Wine stderr/stdout" "$WINE_LOG" 260
    dump_file_tail "Wine minidump helper" "${DIAGNOSTIC_DIR}/latest-winedbg-minidump.log" 160
    dump_file_tail "recent input events" "$INPUT_TRACE" 300
    dump_file_tail "ddraw log" "${GAME_DIR}/ddraw.log" 160
    dump_file_tail "cnc-ddraw log" "${GAME_DIR}/cnc-ddraw.log" 160
    dump_file_tail "RA2 exception" "${GAME_DIR}/except.txt" 200
    dump_file_tail "Yuri exception" "${GAME_DIR}/except_yr.txt" 200
    dump_file_tail "Xvfb init log" "/tmp/ra2-xvfb-init.log" 80
  } >"$report" 2>&1 || true
  cp "$report" "${DIAGNOSTIC_DIR}/latest-crash.log" 2>/dev/null || true
  cp "$report" "${DIAGNOSTIC_DIR}/last-lockup.txt" 2>/dev/null || true
  log "crash report written to ${report}"
  log "latest crash report: ${DIAGNOSTIC_DIR}/latest-crash.log"
  sed 's/^/[ultra-game] diagnostic: /' "$report" 2>/dev/null || true
}

prepare_game_work_dir
cd "$GAME_DIR"
log "starting ${GAME_EXE}; supervising ${GAME_PROCESS}; game_dir=${GAME_DIR}; assets=${ASSETS_DIR}; cpuset=${GAME_CPUSET}"
if [ -f "$WINE_LOG" ]; then
  cp "$WINE_LOG" "${DIAGNOSTIC_DIR}/wine-previous.log" 2>/dev/null || true
fi
{
  printf '[ultra-game] wine launch at %s exe=%s debug=%s\n' "$(date -Iseconds 2>/dev/null || date)" "$GAME_EXE" "$WINE_DEBUG_CHANNELS"
} >"$WINE_LOG" 2>/dev/null || true
if command -v taskset >/dev/null 2>&1 && [ -n "$GAME_CPUSET" ]; then
  WINEDEBUG="$WINE_DEBUG_CHANNELS" taskset -c "$GAME_CPUSET" /opt/wine/bin/wine "${GAME_DIR}/${GAME_EXE}" -SPEEDCONTROL >>"$WINE_LOG" 2>&1 &
else
  WINEDEBUG="$WINE_DEBUG_CHANNELS" /opt/wine/bin/wine "${GAME_DIR}/${GAME_EXE}" -SPEEDCONTROL >>"$WINE_LOG" 2>&1 &
fi
wine_pid="$!"

trap 'log "stop requested"; stop_wine; wait "$wine_pid" 2>/dev/null || true; exit 0' INT TERM

started_at="$(date +%s)"
seen_game=0

while kill -0 "$wine_pid" 2>/dev/null; do
  if [ "$(zombie_game_count)" -gt 0 ]; then
    log "${GAME_PROCESS} is defunct; restarting Wine"
    dump_lockup_report "zombie-${GAME_PROCESS}"
    stop_wine
    wait "$wine_pid" 2>/dev/null || true
    exit 1
  fi

  if [ "$(live_game_count)" -gt 0 ]; then
    seen_game=1
    pin_game_affinity
  elif [ "$seen_game" = "1" ]; then
    log "${GAME_PROCESS} exited; restarting Wine"
    dump_lockup_report "exited-${GAME_PROCESS}"
    stop_wine
    wait "$wine_pid" 2>/dev/null || true
    exit 1
  elif [ "$(($(date +%s) - started_at))" -gt "$READY_TIMEOUT" ]; then
    log "${GAME_PROCESS} did not become ready within ${READY_TIMEOUT}s"
    dump_lockup_report "ready-timeout-${GAME_PROCESS}"
    stop_wine
    wait "$wine_pid" 2>/dev/null || true
    exit 1
  fi

  sleep 2
done

set +e
wait "$wine_pid"
status="$?"
set -e
log "wine exited with status ${status}"
dump_lockup_report "wine-exit-${status}"
exit "$status"
