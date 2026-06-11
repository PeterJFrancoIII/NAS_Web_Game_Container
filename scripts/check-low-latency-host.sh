#!/bin/sh
set -eu

CONTAINER="${RA2_WEBRTC_CONTAINER:-ra2-player-1}"
DRI_DEVICE="${DRI_DEVICE:-/dev/dri/renderD128}"
MEMORY_STRICT="${RA2_MEMORY_STRICT:-0}"
SWAP_WARN_KIB="${RA2_SWAP_WARN_KIB:-262144}"
AVAIL_WARN_MIB="${RA2_AVAIL_WARN_MIB:-512}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
WARN=0

if [ -f "$SCRIPT_DIR/lib.sh" ]; then
  . "$SCRIPT_DIR/lib.sh"
else
  run_docker() {
    docker "$@"
  }
fi

warn() {
  printf 'WARN: %s\n' "$1"
  WARN=1
}

ok() {
  printf 'OK: %s\n' "$1"
}

section() {
  printf '\n== %s ==\n' "$1"
}

section "Host memory and swap"
if command -v free >/dev/null 2>&1; then
  free -h
  mem_total_mib="$(free -m | awk '/^Mem:/ {print $2}')"
  mem_avail_mib="$(free -m | awk '/^Mem:/ {print $7}')"
  swap_used_kib="$(free | awk '/^Swap:/ {print $3}')"
  printf 'available memory: %s MiB / %s MiB\n' "${mem_avail_mib:-?}" "${mem_total_mib:-?}"
  if [ -n "${mem_total_mib:-}" ] && [ "$mem_total_mib" -lt 6144 ] 2>/dev/null; then
    warn "total RAM ${mem_total_mib} MiB < 6144 MiB production baseline — Moonlight primary needs 6 GB upgrade"
  fi
  if [ "${swap_used_kib:-0}" -gt "$SWAP_WARN_KIB" ] 2>/dev/null; then
    warn "swap is in use (${swap_used_kib} KiB > ${SWAP_WARN_KIB} KiB threshold)"
  elif [ "${swap_used_kib:-0}" -gt 0 ] 2>/dev/null; then
    warn "swap is in use (${swap_used_kib} KiB) — expect latency spikes during play"
  else
    ok "swap not in use"
  fi
  if [ -n "${mem_avail_mib:-}" ] && [ "$mem_avail_mib" -lt "$AVAIL_WARN_MIB" ] 2>/dev/null; then
    warn "available memory below ${AVAIL_WARN_MIB} MiB — avoid launching player 2"
  fi
else
  warn "free command unavailable"
fi

section "GPU device permissions"
if [ -e "$DRI_DEVICE" ]; then
  ls -l "$DRI_DEVICE"
  if [ ! -r "$DRI_DEVICE" ] || [ ! -w "$DRI_DEVICE" ]; then
    warn "${DRI_DEVICE} is not readable/writable by current user"
  else
    ok "${DRI_DEVICE} accessible on host"
  fi
else
  warn "${DRI_DEVICE} missing — VA-API hardware encode will fail"
fi

if [ -d /dev/dri ]; then
  ls -l /dev/dri
fi

UINPUT_DEVICE="${UINPUT_DEVICE:-/dev/uinput}"
section "Virtual input device (/dev/uinput)"
if [ -e "$UINPUT_DEVICE" ]; then
  ls -l "$UINPUT_DEVICE"
  if [ ! -r "$UINPUT_DEVICE" ] || [ ! -w "$UINPUT_DEVICE" ]; then
    warn "${UINPUT_DEVICE} is not readable/writable — uinput backend will fall back to xdotool"
  else
    ok "${UINPUT_DEVICE} accessible on host"
  fi
else
  warn "${UINPUT_DEVICE} missing — run: sudo sh scripts/prepare-streaming-session.sh (or install uinput.ko)"
fi

section "Container memory usage"
if run_docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^ra2-player-'; then
  run_docker stats --no-stream ra2-player-1 ra2-player-2 2>/dev/null || \
    run_docker stats --no-stream ra2-player-1 2>/dev/null || \
    warn "docker stats unavailable"
else
  warn "no ra2-player containers running"
fi

check_container() {
  name="$1"
  if ! run_docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
    warn "container ${name} not running"
    return
  fi

  printf '\n-- %s --\n' "$name"
  helper_count="$(run_docker exec "$name" sh -lc 'pgrep -fc "^/opt/ra2/webrtc-media-helper" || true')"
  bridge_count="$(run_docker exec "$name" sh -lc 'pgrep -fc "/opt/ra2/webrtc-media.py" || true')"
  printf 'webrtc-media.py processes: %s\n' "$bridge_count"
  printf 'webrtc-media-helper processes: %s\n' "$helper_count"
  if [ "$helper_count" -gt 1 ]; then
    warn "${name}: multiple helper processes detected"
    run_docker exec "$name" sh -lc 'pgrep -af webrtc-media-helper || true'
  elif [ "$helper_count" -eq 0 ]; then
    warn "${name}: no helper process (idle until a browser connects)"
  else
    ok "${name}: single helper process while session active"
  fi

  game_state="$(run_docker exec "$name" sh -lc 'ps -eo pid,ppid,stat,comm,args 2>/dev/null | awk "/RA2MD|gamemd/ && !/awk/ {print}" || true')"
  zombie_state="$(printf '%s\n' "$game_state" | awk '$3 ~ /^Z/ {print}')"
  if [ -n "$zombie_state" ]; then
    warn "${name}: game process is zombie/defunct"
    printf '%s\n' "$zombie_state"
  elif [ -z "$game_state" ]; then
    warn "${name}: no RA2MD/gamemd process visible"
  else
    ok "${name}: game process running"
    printf '%s\n' "$game_state"
  fi

  run_docker exec "$name" sh -lc '
    env | grep -E "^RA2_(MEMORY|ENABLE)|^WEBRTC_(VIDEO|LATENCY|ENABLED|ICE|INPUT)" || true
    test -x /opt/ra2/webrtc-media-helper && echo "webrtc-media-helper present" || echo "webrtc-media-helper missing"
    gst-inspect-1.0 vah264enc 2>/dev/null | head -n 3 || echo "vah264enc missing"
    gst-inspect-1.0 vah265enc 2>/dev/null | head -n 3 || echo "vah265enc missing"
    gst-inspect-1.0 x264enc 2>/dev/null | head -n 3 || echo "x264enc missing"
    test -r /dev/dri/renderD128 && echo "container can read /dev/dri/renderD128" || echo "container cannot read /dev/dri/renderD128"
    test -r /dev/uinput && echo "container can read /dev/uinput" || echo "container cannot read /dev/uinput"
  '
  require_hw="$(run_docker exec "$name" sh -lc 'printf "%s" "${WEBRTC_VIDEO_REQUIRE_HW:-0}"')"
  codec="$(run_docker exec "$name" sh -lc 'printf "%s" "${WEBRTC_VIDEO_CODEC:-H264}"')"
  if [ "$require_hw" = "1" ]; then
    case "$codec" in
      H264|h264|AVC|avc)
        run_docker exec "$name" sh -lc 'gst-inspect-1.0 vah264enc >/dev/null 2>&1 || gst-inspect-1.0 vaapih264enc >/dev/null 2>&1' || \
          warn "${name}: WEBRTC_VIDEO_REQUIRE_HW=1 but no GStreamer H.264 VA encoder is available"
        ;;
      H265|h265|HEVC|hevc)
        run_docker exec "$name" sh -lc 'gst-inspect-1.0 vah265enc >/dev/null 2>&1 || gst-inspect-1.0 vaapih265enc >/dev/null 2>&1' || \
          warn "${name}: WEBRTC_VIDEO_REQUIRE_HW=1 but no GStreamer HEVC VA encoder is available"
        ;;
    esac
  fi
}

section "Container WebRTC and game health"
check_container ra2-player-1
check_container ra2-player-2

section "Listening ports"
if command -v ss >/dev/null 2>&1; then
  ss -lun | grep -E ':(608[1-6]|6200[0-9]|6201[0-9]|62020)\b' || warn "expected WebRTC/noVNC ports not bound"
elif command -v netstat >/dev/null 2>&1; then
  netstat -lun | grep -E ':(608[1-6]|6200[0-9]|6201[0-9]|62020)\b' || warn "expected WebRTC/noVNC ports not bound"
else
  warn "ss/netstat unavailable for port checks"
fi

section "Recommendations"
printf '%s\n' \
  "- Primary play path: Moonlight client + Sunshine/Wolf (see docs/MOONLIGHT_EXPERIMENT.md)." \
  "- Admin/recovery: noVNC on ports 6081/6082 (vnc.html)." \
  "- WebRTC remote.html is legacy fallback only — run scripts/check-webrtc-ice-reachability.sh if video is blank." \
  "- Production RAM baseline: 6 GB (stock 1.7 GB is testing/fallback only)." \
  "- Prefer wired 2.5GbE or 1GbE when measuring latency." \
  "- Use wired Ethernet on client and NAS when measuring latency." \
  "- Disable DSM indexing, antivirus, and media scans during play sessions." \
  "- For two-player DS225+, keep RA2_MEM_LIMIT=512m and RA2_ENABLE_AUDIO_PROXY=0." \
  "- Before streaming: sudo sh scripts/prepare-streaming-session.sh (boot task deferred)."

if [ "$WARN" -ne 0 ]; then
  printf '\nHost check completed with warnings.\n'
  if [ "$MEMORY_STRICT" = "1" ]; then
    exit 1
  fi
  exit 0
fi

printf '\nHost check passed.\n'
