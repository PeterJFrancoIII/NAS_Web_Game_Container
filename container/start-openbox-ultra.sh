#!/bin/sh
# Minimal Openbox session — locked config only; no autostart, no user rc.xml.
set -eu

export DISPLAY="${DISPLAY:-:1}"
OB_CONFIG="/opt/ra2/openbox/rc.xml"

if [ ! -f "$OB_CONFIG" ]; then
  printf '[openbox] missing config: %s\n' "$OB_CONFIG" >&2
  exit 1
fi

exec openbox --config-file "$OB_CONFIG"
