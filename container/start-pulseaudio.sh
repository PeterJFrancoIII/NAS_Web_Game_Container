#!/usr/bin/env bash
set -euo pipefail

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/pulse-runtime}"
export PULSE_RUNTIME_PATH="${PULSE_RUNTIME_PATH:-$XDG_RUNTIME_DIR/pulse}"

mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
mkdir -p /tmp/pulse
chmod 700 /tmp/pulse

exec /usr/bin/pulseaudio \
  --verbose \
  --daemonize=no \
  --exit-idle-time=-1 \
  --disable-shm=yes \
  -n \
  --file=/opt/ra2/pulse/default.pa
