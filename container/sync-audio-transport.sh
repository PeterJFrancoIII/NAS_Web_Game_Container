#!/bin/sh
# Keep PulseAudio native capture aligned with transport audio settings.
set -eu

NATIVE_RATE="${1:-44100}"
TRANSPORT_RATE="${2:-$NATIVE_RATE}"
AUDIO_ENCODER="${3:-opus}"

log() {
  printf '[ultra-audio-sync] %s\n' "$*" >&2
}

if [ "$TRANSPORT_RATE" != "$NATIVE_RATE" ]; then
  log "warning: transport rate ${TRANSPORT_RATE} != native ${NATIVE_RATE}; using native"
  TRANSPORT_RATE="$NATIVE_RATE"
fi

STATE_DIR="${ULTRA_STATE_DIR:-/home/commander/.ra2}"
PA_FILE="${ULTRA_PULSE_PA:-${STATE_DIR}/pulse.pa}"
RATE_STAMP="${STATE_DIR}/audio-native-rate"
PULSE_PORT="${PULSE_TCP_PORT:-4711}"

mkdir -p "$STATE_DIR"
PREV="$(cat "$RATE_STAMP" 2>/dev/null || true)"

cat >"$PA_FILE" <<EOF
.fail
load-module module-native-protocol-unix auth-anonymous=1 socket=/tmp/pulse/native

load-module module-null-sink sink_name=game sink_properties=device.description=RA2_Game_Audio rate=${NATIVE_RATE}
set-default-sink game
set-default-source game.monitor

load-module module-simple-protocol-tcp listen=127.0.0.1 port=${PULSE_PORT} format=s16le channels=2 rate=${NATIVE_RATE} record=true playback=false
EOF

printf '%s' "$NATIVE_RATE" >"$RATE_STAMP"
log "audio=${NATIVE_RATE}Hz encoder=${AUDIO_ENCODER} pulse=${PA_FILE}"

if command -v supervisorctl >/dev/null 2>&1; then
  if [ -n "$PREV" ] && [ "$PREV" != "$NATIVE_RATE" ]; then
    supervisorctl -c /opt/ra2/supervisord.conf restart pulseaudio >/dev/null 2>&1 || true
    sleep 2
    supervisorctl -c /opt/ra2/supervisord.conf restart game >/dev/null 2>&1 || true
    log "restarted pulseaudio + game for native rate ${PREV} -> ${NATIVE_RATE}"
  fi
fi
