#!/bin/sh
set -eu

REQUESTED_LOG_ROOT="${ULTRA_GAME_LOG_ROOT:-/home/commander/ra2-logs-root}"
DEFAULT_LOG_ROOT="${WINEPREFIX:-/home/commander/.wine}/ra2-crash-logs"
if grep -qs " ${REQUESTED_LOG_ROOT} " /proc/mounts 2>/dev/null; then
  LOG_ROOT="$REQUESTED_LOG_ROOT"
else
  LOG_ROOT="$DEFAULT_LOG_ROOT"
fi

DIAGNOSTIC_DIR="${ULTRA_GAME_DIAGNOSTIC_DIR:-${LOG_ROOT}/player${PLAYER_ID:-unknown}}"
VIDEO_DIAGNOSTICS_LOG="${ULTRA_VIDEO_DIAGNOSTICS_LOG:-${DIAGNOSTIC_DIR}/video-diagnostics.log}"
mkdir -p "$DIAGNOSTIC_DIR" 2>/dev/null || true

run_section() {
  label="$1"
  shift
  printf '\n[ultra-video] --- %s ---\n' "$label"
  "$@" 2>&1 || printf '[ultra-video] command failed: %s\n' "$*"
}

inspect_factory() {
  factory="$1"
  printf '\n[ultra-video] --- gst factory: %s ---\n' "$factory"
  if ! command -v gst-inspect-1.0 >/dev/null 2>&1; then
    printf '[ultra-video] gst-inspect-1.0 missing\n'
    return
  fi
  if gst-inspect-1.0 "$factory" >/tmp/ra2-gst-inspect.out 2>&1; then
    printf '[ultra-video] factory-present %s\n' "$factory"
    sed -n '1,160p' /tmp/ra2-gst-inspect.out
  else
    printf '[ultra-video] factory-missing %s\n' "$factory"
    sed -n '1,80p' /tmp/ra2-gst-inspect.out
  fi
}

{
  printf '[ultra-video] diagnostics at %s\n' "$(date -Iseconds 2>/dev/null || date)"
  printf '[ultra-video] player=%s display=%s codec=%s require_hw=%s driver=%s\n' \
    "${PLAYER_ID:-unknown}" "${DISPLAY:-unknown}" "${ULTRA_VIDEO_CODEC:-H264}" \
    "${ULTRA_VIDEO_REQUIRE_HW:-1}" "${LIBVA_DRIVER_NAME:-unset}"
  printf '[ultra-video] dimensions=%sx%s fps=%s bitrate=%s qsv_probe=%s\n' \
    "${ULTRA_VIDEO_WIDTH:-1024}" "${ULTRA_VIDEO_HEIGHT:-768}" \
    "${ULTRA_VIDEO_FPS:-24}" "${ULTRA_VIDEO_BITRATE:-900000}" \
    "${ULTRA_VIDEO_QSV_DIAGNOSTICS:-1}"

  run_section "kernel" uname -a
  run_section "user" id
  run_section "render devices" ls -l /dev/dri

  if command -v vainfo >/dev/null 2>&1; then
    run_section "vainfo" vainfo
  else
    printf '\n[ultra-video] --- vainfo ---\n'
    printf '[ultra-video] vainfo missing; install libva-utils in the image for VA profile detail\n'
  fi

  if command -v gst-inspect-1.0 >/dev/null 2>&1; then
    run_section "gstreamer version" gst-inspect-1.0 --version
    printf '\n[ultra-video] --- relevant gstreamer factories ---\n'
    gst-inspect-1.0 2>/dev/null | sed -n '/qsv\|msdk\|va.*265\|va.*264\|h265\|hevc\|H265\|HEVC/Ip' | sed -n '1,220p' || true
  else
    printf '\n[ultra-video] --- gstreamer ---\n'
    printf '[ultra-video] gst-inspect-1.0 missing\n'
  fi

  for factory in \
    qsvh265enc qsvh264enc \
    msdkh265enc msdkh264enc \
    vah265enc vah264enc \
    vaapih265enc vaapih264enc \
    h265parse h264parse; do
    inspect_factory "$factory"
  done
} >"$VIDEO_DIAGNOSTICS_LOG" 2>&1 || true

printf '[ultra-video] diagnostics written to %s\n' "$VIDEO_DIAGNOSTICS_LOG" >&2
