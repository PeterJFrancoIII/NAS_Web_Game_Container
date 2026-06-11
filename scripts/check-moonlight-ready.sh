#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

FAIL=0
pass() { printf '[OK] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=1; }
note() { printf '[..] %s\n' "$1"; }

note "Moonlight experiment readiness"

for svc in ra2-sunshine-experiment ra2-wolf-experiment; do
  state="$(container_status "$svc")"
  if [ "$state" = "running" ]; then
    pass "${svc} is running"
  else
    note "${svc} state=${state:-not found} (optional — start with compose.sunshine.yaml or compose.wolf.yaml)"
  fi
done

DRI_DEVICE="${DRI_DEVICE:-/dev/dri/renderD128}"
if [ -e "$DRI_DEVICE" ] && [ -r "$DRI_DEVICE" ] && [ -w "$DRI_DEVICE" ]; then
  pass "${DRI_DEVICE} accessible on host"
else
  fail "${DRI_DEVICE} not ready for VA-API encode"
fi

UINPUT_DEVICE="${UINPUT_DEVICE:-/dev/uinput}"
if [ -e "$UINPUT_DEVICE" ] && [ -r "$UINPUT_DEVICE" ] && [ -w "$UINPUT_DEVICE" ]; then
  pass "${UINPUT_DEVICE} accessible on host"
else
  fail "${UINPUT_DEVICE} missing — Wolf/Sunshine input virtualization needs uinput.ko"
fi

if command -v ss >/dev/null 2>&1; then
  ss -lnt | grep -E ':(4798[4-9]|47990|48010)\b' && pass "GameStream TCP ports listening" || \
    note "GameStream TCP ports not listening — start Sunshine or Wolf first"
  ss -lnu | grep -E ':(4799[89]|48000)\b' && pass "GameStream UDP ports listening" || \
    note "GameStream UDP ports not listening — start Sunshine or Wolf first"
fi

if run_docker ps --format '{{.Names}}' 2>/dev/null | grep -qx ra2-sunshine-experiment; then
  run_docker exec ra2-sunshine-experiment sh -lc \
    'LIBVA_DRIVER_NAME=${LIBVA_DRIVER_NAME:-i965} vainfo --display drm --device /dev/dri/renderD128 2>&1 | head -n 20' || \
    fail "Sunshine container cannot run vainfo"
fi

if run_docker ps --format '{{.Names}}' 2>/dev/null | grep -qx ra2-wolf-experiment; then
  run_docker exec ra2-wolf-experiment sh -lc 'test -S /var/run/docker.sock && echo docker.sock ok' || \
    fail "Wolf container cannot access Docker socket"
fi

note "Run full host gate before production Moonlight:"
note "  sh scripts/check-host-prerequisites.sh"

if [ "$FAIL" -ne 0 ]; then
  printf '\nMoonlight readiness check FAILED.\n'
  exit 1
fi
printf '\nMoonlight readiness check passed.\n'
