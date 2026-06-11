#!/bin/sh
# Hard gate for Moonlight-primary deployments: VA-API, uinput, RAM, and network.
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

ENV_FILE="${ENV_FILE:-.env}"
CONTAINER="${1:-}"
if [ -z "$CONTAINER" ]; then
  if run_docker ps --format '{{.Names}}' 2>/dev/null | grep -qx ra2-wolf-experiment; then
    CONTAINER="ra2-wolf-experiment"
  else
    CONTAINER="ra2-player-1"
  fi
fi
PRODUCTION_RAM_MIB="${RA2_PRODUCTION_RAM_MIB:-6144}"
WARN_ONLY="${RA2_PREREQ_WARN_ONLY:-0}"
FAIL=0

fail() { printf '[FAIL] %s\n' "$1"; FAIL=1; }
pass() { printf '[OK] %s\n' "$1"; }
note() { printf '[..] %s\n' "$1"; }

note "Host prerequisites for Moonlight-primary path"

if command -v free >/dev/null 2>&1; then
  mem_total_mib="$(free -m | awk '/^Mem:/ {print $2}')"
  mem_avail_mib="$(free -m | awk '/^Mem:/ {print $7}')"
  printf 'Memory: %s MiB total, %s MiB available\n' "${mem_total_mib:-?}" "${mem_avail_mib:-?}"
  if [ -n "${mem_total_mib:-}" ] && [ "$mem_total_mib" -lt "$PRODUCTION_RAM_MIB" ] 2>/dev/null; then
    if [ "$WARN_ONLY" = "1" ]; then
      printf '[WARN] %s MiB RAM is below %s MiB production baseline — fallback/testing only\n' \
        "$mem_total_mib" "$PRODUCTION_RAM_MIB"
    else
      fail "RAM ${mem_total_mib} MiB < ${PRODUCTION_RAM_MIB} MiB production baseline (upgrade to 6 GB)"
    fi
  else
    pass "RAM meets production baseline (${PRODUCTION_RAM_MIB} MiB)"
  fi
else
  fail "free command unavailable"
fi

DRI_DEVICE="${DRI_DEVICE:-/dev/dri/renderD128}"
if [ -e "$DRI_DEVICE" ] && [ -r "$DRI_DEVICE" ] && [ -w "$DRI_DEVICE" ]; then
  pass "${DRI_DEVICE} accessible"
else
  fail "${DRI_DEVICE} missing or not readable/writable — VA-API encode will fail"
fi

UINPUT_DEVICE="${UINPUT_DEVICE:-/dev/uinput}"
if [ -e "$UINPUT_DEVICE" ] && [ -r "$UINPUT_DEVICE" ] && [ -w "$UINPUT_DEVICE" ]; then
  pass "${UINPUT_DEVICE} accessible"
else
  fail "${UINPUT_DEVICE} missing — run: sudo sh scripts/prepare-streaming-session.sh (or install uinput.ko)"
fi

if command -v ethtool >/dev/null 2>&1; then
  iface="${NAS_LAN_INTERFACE:-eth0}"
  speed="$(ethtool "$iface" 2>/dev/null | awk -F': ' '/Speed:/ {print $2}' || true)"
  if [ -n "$speed" ]; then
    printf 'Link speed (%s): %s\n' "$iface" "$speed"
    case "$speed" in
      *2500*|*10000*|*1000*)
        pass "wired link detected (${speed})"
        ;;
      *)
        printf '[WARN] prefer 2.5GbE or 1GbE wired Ethernet for latency testing (got %s)\n' "$speed"
        ;;
    esac
  else
    printf '[WARN] could not read link speed for %s\n' "$iface"
  fi
else
  note "ethtool unavailable — verify wired 2.5GbE/1GbE manually"
fi

note "VA-API transcode smoke test (${CONTAINER})"
if sh "$SCRIPT_DIR/check-transcode.sh" "$CONTAINER"; then
  pass "VA-API transcode checks passed"
else
  fail "VA-API transcode checks failed — run scripts/enable-host-transcode.sh"
fi

if [ "$FAIL" -ne 0 ]; then
  printf '\nHost prerequisites FAILED.\n'
  exit 1
fi
printf '\nHost prerequisites PASSED.\n'
