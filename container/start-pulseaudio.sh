#!/usr/bin/env bash
set -euo pipefail

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/pulse-runtime}"
export PULSE_RUNTIME_PATH="${PULSE_RUNTIME_PATH:-$XDG_RUNTIME_DIR/pulse}"

mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
mkdir -p /tmp/pulse
chmod 700 /tmp/pulse

if [ "${ULTRA_AUDIO_CODEC:-opus}" = "opus" ]; then
  NATIVE_RATE="${ULTRA_AUDIO_RATE:-48000}"
else
  NATIVE_RATE="${ULTRA_AUDIO_RATE:-44100}"
fi
TRANSPORT_RATE="${ULTRA_AUDIO_TRANSPORT_RATE:-$NATIVE_RATE}"
AUDIO_ENCODER="${ULTRA_AUDIO_CODEC:-opus}"
PA_FILE="${ULTRA_PULSE_PA:-/home/commander/.ra2/pulse.pa}"

if [ -x /opt/ra2/sync-audio-transport.sh ]; then
  /bin/sh /opt/ra2/sync-audio-transport.sh "$NATIVE_RATE" "$TRANSPORT_RATE" "$AUDIO_ENCODER" || true
fi
if [ ! -f "$PA_FILE" ]; then
  PA_FILE="/opt/ra2/pulse/default.pa"
fi

exec /usr/bin/pulseaudio \
  --verbose \
  --daemonize=no \
  --exit-idle-time=-1 \
  --disable-shm=yes \
  -n \
  --file="$PA_FILE"
