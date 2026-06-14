#!/bin/sh
set -eu

pid="${1:-}"
event="${2:-}"
log_root="${ULTRA_GAME_LOG_ROOT:-/home/commander/ra2-logs-root}"
diagnostic_dir="${ULTRA_GAME_DIAGNOSTIC_DIR:-${log_root}/player${PLAYER_ID:-unknown}}"

mkdir -p "$diagnostic_dir" 2>/dev/null || true
stamp="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%s)"
dump="${diagnostic_dir}/minidump-${stamp}-pid${pid:-unknown}.mdmp"
log="${diagnostic_dir}/winedbg-minidump-${stamp}-pid${pid:-unknown}.log"

{
  printf '[winedbg-minidump] pid=%s event=%s dump=%s\n' "$pid" "$event" "$dump"
  if [ -z "$pid" ]; then
    printf '[winedbg-minidump] missing pid\n'
    exit 1
  fi

  if [ -n "$event" ]; then
    printf '[winedbg-minidump] auto-debug begin\n'
    timeout 20 /opt/wine/bin/winedbg --auto "$pid" "$event" || printf '[winedbg-minidump] auto-debug exit=%s\n' "$?"
    printf '[winedbg-minidump] auto-debug end\n'
  fi

  printf '[winedbg-minidump] minidump begin\n'
  timeout 20 /opt/wine/bin/winedbg --minidump "$dump" "$pid" || printf '[winedbg-minidump] minidump exit=%s\n' "$?"
  if [ -f "$dump" ]; then
    printf '[winedbg-minidump] minidump written bytes=%s\n' "$(wc -c <"$dump" 2>/dev/null || printf unknown)"
  else
    printf '[winedbg-minidump] minidump missing\n'
  fi
} >"$log" 2>&1 || true

cp "$log" "${diagnostic_dir}/latest-winedbg-minidump.log" 2>/dev/null || true
exit 0
