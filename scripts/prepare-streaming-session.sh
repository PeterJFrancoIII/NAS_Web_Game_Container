#!/bin/sh
# One-time (per boot) host prep for Wolf/Moonlight — no DSM Task Scheduler required.
# Permissions reset after NAS reboot; add dsm-boot-task.sh later for persistence.
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"

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

printf '== Manual streaming session prep (no boot task) ==\n'

if [ -d /dev/dri ]; then
  run_root chgrp videodriver /dev/dri/card0 /dev/dri/renderD128 2>/dev/null || true
  run_root chmod 660 /dev/dri/card0 /dev/dri/renderD128 2>/dev/null || true
  run_root chmod 666 /dev/dri/renderD128 2>/dev/null || true
  ls -l /dev/dri/renderD128 2>/dev/null || true
  printf 'OK: /dev/dri permissions set for this session\n'
else
  printf 'WARN: /dev/dri missing — run scripts/enable-host-transcode.sh\n'
fi

if sh "$SCRIPT_DIR/enable-uinput.sh" 2>/dev/null; then
  printf 'OK: uinput ready\n'
else
  printf 'WARN: uinput not available — Wolf streams video but input may not work until uinput.ko is installed\n'
fi

printf '\nNote: these settings are lost on reboot until you add scripts/dsm-boot-task.sh to DSM (optional, deferred).\n'
printf 'Next: sudo sh scripts/redeploy-moonlight-poc.sh wolf\n'
