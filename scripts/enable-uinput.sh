#!/bin/sh
# Try to load /dev/uinput on DSM (modprobe or compiled uinput.ko).
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
UINPUT_KO="${RA2_UINPUT_KO:-/volume2/Data/App_Development/ra2-lan-party/drivers/uinput.ko}"
DRIVERS_DIR="$(dirname "$UINPUT_KO")"

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
    return $?
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
    return $?
  fi
  echo "Run as root or with sudo."
  return 1
}

if [ -e /dev/uinput ]; then
  ls -l /dev/uinput
  echo "OK: /dev/uinput already exists"
  exit 0
fi

echo "Attempting modprobe uinput..."
if run_root modprobe uinput 2>/dev/null; then
  if [ -e /dev/uinput ]; then
    run_root chmod 666 /dev/uinput 2>/dev/null || true
    ls -l /dev/uinput
    echo "OK: uinput loaded via modprobe"
    exit 0
  fi
fi

if [ -f "$UINPUT_KO" ]; then
  echo "Attempting insmod $UINPUT_KO..."
  if run_root insmod "$UINPUT_KO" 2>/dev/null; then
    run_root chmod 666 /dev/uinput 2>/dev/null || true
    ls -l /dev/uinput
    echo "OK: uinput loaded via insmod"
    exit 0
  fi
fi

echo "FAIL: /dev/uinput not available."
echo "Place compiled uinput.ko in: $DRIVERS_DIR"
echo "Or run: sudo sh scripts/prepare-streaming-session.sh (manual, per boot)."
echo "Persistent boot setup (deferred): scripts/dsm-boot-task.sh in DSM Task Scheduler."
echo "See docs/CONSOLIDATED_ARCHITECTURE.md section 7."
exit 1
