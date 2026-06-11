#!/bin/sh
# OPTIONAL / DEFERRED — persistent boot-time device prep for streaming stacks.
# Skip for now; use scripts/prepare-streaming-session.sh per session instead.
# When ready: paste into Control Panel -> Task Scheduler -> Triggered Task -> Boot-up
#
# Adapt paths for your NAS volume layout before saving in DSM.
set -eu

TRANSCODE_SCRIPT="${RA2_TRANSCODE_SCRIPT:-/volume2/Data/App_Development/ra2-lan-party/drivers/transcode_for_x25.sh}"
UINPUT_KO="${RA2_UINPUT_KO:-/volume2/Data/App_Development/ra2-lan-party/drivers/uinput.ko}"

if [ -x "$TRANSCODE_SCRIPT" ]; then
  "$TRANSCODE_SCRIPT" --autoupdate=3 2>/dev/null || true
fi

modprobe uinput 2>/dev/null || true

if [ ! -e /dev/uinput ] && [ -f "$UINPUT_KO" ]; then
  insmod "$UINPUT_KO" 2>/dev/null || true
fi

sleep 2

if [ -d /dev/dri ]; then
  chgrp videodriver /dev/dri/card0 /dev/dri/renderD128 2>/dev/null || true
  chmod 660 /dev/dri/card0 /dev/dri/renderD128 2>/dev/null || true
  chmod 666 /dev/dri/renderD128 2>/dev/null || true
fi

if [ -e /dev/uinput ]; then
  chmod 666 /dev/uinput 2>/dev/null || true
fi

printf 'dsm-boot-task: dri=%s uinput=%s\n' \
  "$([ -e /dev/dri/renderD128 ] && echo ok || echo missing)" \
  "$([ -e /dev/uinput ] && echo ok || echo missing)"
