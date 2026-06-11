#!/bin/sh
set -eu

if [ "${WEBRTC_ENABLED:-0}" != "1" ]; then
  printf '[webrtc] disabled (WEBRTC_ENABLED=%s)\n' "${WEBRTC_ENABLED:-0}" >&2
  exit 0
fi

export DISPLAY="${DISPLAY:-:1}"
export WEBRTC_SIGNAL_PORT="${WEBRTC_SIGNAL_PORT:-6090}"
export WEBRTC_UDP_PORT_MIN="${WEBRTC_UDP_PORT_MIN:-62001}"
export WEBRTC_UDP_PORT_MAX="${WEBRTC_UDP_PORT_MAX:-62020}"
udp_mid=$((WEBRTC_UDP_PORT_MIN + ((WEBRTC_UDP_PORT_MAX - WEBRTC_UDP_PORT_MIN + 1) / 2) - 1))
export WEBRTC_VIDEO_UDP_PORT_MIN="${WEBRTC_VIDEO_UDP_PORT_MIN:-$WEBRTC_UDP_PORT_MIN}"
export WEBRTC_VIDEO_UDP_PORT_MAX="${WEBRTC_VIDEO_UDP_PORT_MAX:-$udp_mid}"
export WEBRTC_AUDIO_UDP_PORT_MIN="${WEBRTC_AUDIO_UDP_PORT_MIN:-$((udp_mid + 1))}"
export WEBRTC_AUDIO_UDP_PORT_MAX="${WEBRTC_AUDIO_UDP_PORT_MAX:-$WEBRTC_UDP_PORT_MAX}"
export WEBRTC_ICE_TCP="${WEBRTC_ICE_TCP:-1}"
export WEBRTC_ICE_UDP="${WEBRTC_ICE_UDP:-1}"
export STUN_URL="${STUN_URL:-stun:stun.l.google.com:19302}"
export WEBRTC_VIDEO_REQUIRE_HW="${WEBRTC_VIDEO_REQUIRE_HW:-1}"
export WEBRTC_VIDEO_KEYFRAME_SECONDS="${WEBRTC_VIDEO_KEYFRAME_SECONDS:-1}"
export WEBRTC_VIDEO_RTP_MTU="${WEBRTC_VIDEO_RTP_MTU:-1000}"
export WEBRTC_OFFER_WAIT_SECONDS="${WEBRTC_OFFER_WAIT_SECONDS:-30}"
export WEBRTC_AUDIO_BITRATE="${WEBRTC_AUDIO_BITRATE:-96000}"
export WEBRTC_AUDIO_FRAME_MS="${WEBRTC_AUDIO_FRAME_MS:-10}"
export WEBRTC_AUDIO_RATE="${WEBRTC_AUDIO_RATE:-44100}"
export PULSE_TCP_PORT="${PULSE_TCP_PORT:-4711}"
export GST_VA_ALL_DRIVERS="${GST_VA_ALL_DRIVERS:-1}"
export WEBRTC_MEDIA_HELPER="${WEBRTC_MEDIA_HELPER:-/opt/ra2/webrtc-media-helper}"

# Memory profile can tighten capture/encode defaults before latency preset applies.
RA2_MEMORY_PROFILE="${RA2_MEMORY_PROFILE:-two-player-low}"
case "$RA2_MEMORY_PROFILE" in
  two-player-low)
    export RESOLUTION="${RESOLUTION:-1024x768}"
    export WEBRTC_LATENCY_PRESET="${WEBRTC_LATENCY_PRESET:-stable}"
    ;;
  *)
    export WEBRTC_LATENCY_PRESET="${WEBRTC_LATENCY_PRESET:-stable}"
    ;;
esac

# Latency presets map to known-good capture/encode values. Explicit env vars win.
case "$WEBRTC_LATENCY_PRESET" in
  stable)
    if [ "$RA2_MEMORY_PROFILE" = "two-player-low" ]; then
      export WEBRTC_VIDEO_CODEC="${WEBRTC_VIDEO_CODEC:-H264}"
      export WEBRTC_VIDEO_WIDTH="${WEBRTC_VIDEO_WIDTH:-1024}"
      export WEBRTC_VIDEO_HEIGHT="${WEBRTC_VIDEO_HEIGHT:-768}"
      export WEBRTC_VIDEO_FPS="${WEBRTC_VIDEO_FPS:-20}"
      export WEBRTC_VIDEO_BITRATE="${WEBRTC_VIDEO_BITRATE:-800000}"
    else
      export WEBRTC_VIDEO_CODEC="${WEBRTC_VIDEO_CODEC:-H264}"
      export WEBRTC_VIDEO_WIDTH="${WEBRTC_VIDEO_WIDTH:-1024}"
      export WEBRTC_VIDEO_HEIGHT="${WEBRTC_VIDEO_HEIGHT:-768}"
      export WEBRTC_VIDEO_FPS="${WEBRTC_VIDEO_FPS:-24}"
      export WEBRTC_VIDEO_BITRATE="${WEBRTC_VIDEO_BITRATE:-1000000}"
    fi
    ;;
  low)
    export WEBRTC_VIDEO_CODEC="${WEBRTC_VIDEO_CODEC:-H264}"
    export WEBRTC_VIDEO_WIDTH="${WEBRTC_VIDEO_WIDTH:-1024}"
    export WEBRTC_VIDEO_HEIGHT="${WEBRTC_VIDEO_HEIGHT:-768}"
    export WEBRTC_VIDEO_FPS="${WEBRTC_VIDEO_FPS:-30}"
    export WEBRTC_VIDEO_BITRATE="${WEBRTC_VIDEO_BITRATE:-1500000}"
    ;;
  experimental)
    # H265 encodes server-side but Safari did not render HEVC in this WebRTC path.
    export WEBRTC_VIDEO_CODEC="${WEBRTC_VIDEO_CODEC:-H265}"
    export WEBRTC_VIDEO_WIDTH="${WEBRTC_VIDEO_WIDTH:-1280}"
    export WEBRTC_VIDEO_HEIGHT="${WEBRTC_VIDEO_HEIGHT:-720}"
    export WEBRTC_VIDEO_FPS="${WEBRTC_VIDEO_FPS:-30}"
    export WEBRTC_VIDEO_BITRATE="${WEBRTC_VIDEO_BITRATE:-2000000}"
    ;;
  *)
    printf '[webrtc] unknown WEBRTC_LATENCY_PRESET=%s (use stable|low|experimental)\n' \
      "$WEBRTC_LATENCY_PRESET" >&2
    exit 1
    ;;
esac

printf '[webrtc] memory profile=%s latency preset=%s codec=%s %sx%s@%sfps bitrate=%s require_hw=%s rtp_mtu=%s ice_udp=%s ice_tcp=%s\n' \
  "$RA2_MEMORY_PROFILE" \
  "$WEBRTC_LATENCY_PRESET" \
  "$WEBRTC_VIDEO_CODEC" \
  "$WEBRTC_VIDEO_WIDTH" \
  "$WEBRTC_VIDEO_HEIGHT" \
  "$WEBRTC_VIDEO_FPS" \
  "$WEBRTC_VIDEO_BITRATE" \
  "$WEBRTC_VIDEO_REQUIRE_HW" \
  "$WEBRTC_VIDEO_RTP_MTU" \
  "$WEBRTC_ICE_UDP" \
  "$WEBRTC_ICE_TCP" >&2

TLS_CERT="${TLS_CERT:-/opt/ra2/tls/cert.pem}"
TLS_KEY="${TLS_KEY:-/opt/ra2/tls/key.pem}"
case "${WEBRTC_SIGNAL_TLS:-}" in
  1|true|yes)
    export WEBRTC_SIGNAL_TLS=1
    ;;
  0|false|no)
    export WEBRTC_SIGNAL_TLS=0
    ;;
  "")
    if [ -f "$TLS_CERT" ] && [ -f "$TLS_KEY" ]; then
      export WEBRTC_SIGNAL_TLS=1
    else
      export WEBRTC_SIGNAL_TLS=0
    fi
    ;;
esac

if [ "${WEBRTC_RECOMPILE_HELPER:-0}" = "1" ] \
  && [ -f /opt/ra2/webrtc-media-helper.c ] \
  && { [ ! -x "$WEBRTC_MEDIA_HELPER" ] || [ /opt/ra2/webrtc-media-helper.c -nt "$WEBRTC_MEDIA_HELPER" ]; }; then
  if ! command -v gcc >/dev/null 2>&1 || ! command -v pkg-config >/dev/null 2>&1; then
    printf '[webrtc] WEBRTC_RECOMPILE_HELPER=1 but gcc/pkg-config are unavailable\n' >&2
    exit 1
  fi
  printf '[webrtc] recompiling media helper\n' >&2
  gcc /opt/ra2/webrtc-media-helper.c -o "$WEBRTC_MEDIA_HELPER" \
    $(pkg-config --cflags --libs gstreamer-1.0 gstreamer-webrtc-1.0 gstreamer-sdp-1.0)
elif [ ! -x "$WEBRTC_MEDIA_HELPER" ]; then
  printf '[webrtc] missing compiled helper at %s\n' "$WEBRTC_MEDIA_HELPER" >&2
  exit 1
fi

exec /usr/bin/python3 /opt/ra2/webrtc-media.py
