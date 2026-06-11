#!/bin/sh
# Low-latency Opus audio proxy for the noVNC audio plugin.
# Based on https://github.com/me-asri/noVNC-audio-plugin

if [ "${RA2_ENABLE_AUDIO_PROXY:-1}" = "0" ]; then
  printf '[audio-proxy] disabled (RA2_ENABLE_AUDIO_PROXY=0)\n' >&2
  exit 0
fi

readonly SCRIPT="$0"

readonly PULSE_PORT='4711'
readonly PULSE_FORMAT='s16le'
readonly PULSE_SAMPLE_RATE='44100'
readonly PULSE_CHANNELS='2'
readonly TCP_BIND='127.0.0.1'
readonly DEFAULT_AUDIO_BITRATE="${AUDIO_BITRATE:-96000}"
readonly DEFAULT_WEBM_CLUSTER_MS="${AUDIO_WEBM_CLUSTER_MS:-100}"
readonly DEFAULT_OPUS_FRAME_MS="${AUDIO_OPUS_FRAME_MS:-20}"
readonly DEFAULT_QUEUE_BUFFERS="${AUDIO_QUEUE_BUFFERS:-8}"

print_usage() {
  echo "Usage: ${SCRIPT} [OPTION]..."
  echo "Audio proxy for noVNC browser playback"
  echo
  echo 'Options:'
  echo " -p : raw audio source port (default: ${PULSE_PORT})"
  echo ' -l : listen for clients on specified TCP port'
  echo " -b : bind TCP listener to specified host (default: ${TCP_BIND})"
  echo " -f : raw audio source format (default: ${PULSE_FORMAT})"
  echo " -r : raw audio source sample rate (default: ${PULSE_SAMPLE_RATE})"
  echo " -c : raw audio source channel count (default: ${PULSE_CHANNELS})"
}

error() {
  echo "$1" >&2
  exit 1
}

usage_error() {
  echo "$1" >&2
  print_usage >&2
  exit 1
}

proto_ready() {
  echo "READY"
}

proto_error() {
  echo "ERR:$1"
  exit 1
}

opus_proxy() {
  pulse_port="$1"
  pulse_format="$2"
  pulse_sample_rate="$3"
  pulse_channels="$4"
  bitrate="$5"
  cluster_ms="$6"
  opus_frame_ms="$7"
  queue_buffers="$8"
  cluster_ns=$((cluster_ms * 1000000))

  proto_ready

  exec gst-launch-1.0 -q webmmux name=mux streamable=true min-cluster-duration="${cluster_ns}" ! fdsink fd=1 \
    tcpclientsrc port="${pulse_port}" ! queue max-size-buffers="${queue_buffers}" leaky=downstream ! \
    rawaudioparse use-sink-caps=false format=pcm pcm-format="${pulse_format}" sample-rate="${pulse_sample_rate}" num-channels="${pulse_channels}" ! \
    audioconvert ! audioresample ! opusenc audio-type=restricted-lowdelay bitrate="${bitrate}" bitrate-type=0 complexity=0 frame-size="${opus_frame_ms}" ! mux.audio_0
}

proxy() {
  pulse_port="$1"
  pulse_format="$2"
  pulse_sample_rate="$3"
  pulse_channels="$4"

  codec='opus'
  bitrate="${DEFAULT_AUDIO_BITRATE}"
  sample_rate='44100'
  cluster_ms="${DEFAULT_WEBM_CLUSTER_MS}"
  opus_frame_ms="${DEFAULT_OPUS_FRAME_MS}"
  queue_buffers="${DEFAULT_QUEUE_BUFFERS}"

  line=''
  while IFS= read -r line; do
    if [ -z "${line}" ]; then
      break
    fi

    case "${line}" in
      *':'*) ;;
      *) proto_error 'bad handshake' ;;
    esac

    opt="$(echo "${line}" | cut -d ':' -f 1)"
    val="$(echo "${line}" | cut -d ':' -f 2-)"

    case "${opt}" in
      CD) codec="${val}" ;;
      BR) bitrate="${val}" ;;
      SR) sample_rate="${val}" ;;
      CM) cluster_ms="${val}" ;;
      FM) opus_frame_ms="${val}" ;;
      QB) queue_buffers="${val}" ;;
      *) proto_error "invalid option ${opt}" ;;
    esac
  done

  case "${codec}" in
    opus)
      opus_proxy "${pulse_port}" "${pulse_format}" "${pulse_sample_rate}" "${pulse_channels}" "${bitrate}" "${cluster_ms}" "${opus_frame_ms}" "${queue_buffers}"
      ;;
    *)
      proto_error "invalid codec ${codec}"
      ;;
  esac
}

server() {
  pulse_port="${PULSE_PORT}"
  pulse_format="${PULSE_FORMAT}"
  pulse_sample_rate="${PULSE_SAMPLE_RATE}"
  pulse_channels="${PULSE_CHANNELS}"
  tcp_port=''
  tcp_bind="${TCP_BIND}"

  while getopts 'p:l:b:f:r:c:h' opt; do
    case "${opt}" in
      p) pulse_port="${OPTARG}" ;;
      l) tcp_port="${OPTARG}" ;;
      b) tcp_bind="${OPTARG}" ;;
      f) pulse_format="${OPTARG}" ;;
      r) pulse_sample_rate="${OPTARG}" ;;
      c) pulse_channels="${OPTARG}" ;;
      h)
        print_usage
        exit 0
        ;;
      *)
        print_usage
        exit 1
        ;;
    esac
  done
  shift $((OPTIND - 1))

  if [ -z "${tcp_port}" ]; then
    usage_error 'Listening TCP port is required (-l)'
  fi

  echo "Raw source port: ${pulse_port}"
  echo "Raw source format: ${pulse_format}"
  echo "Raw source sample rate: ${pulse_sample_rate}"
  echo "Raw source channels: ${pulse_channels}"
  echo "Server listening on ${tcp_bind}:${tcp_port}"

  proxy_cmd="/bin/sh ${SCRIPT} proxy ${pulse_port} ${pulse_format} ${pulse_sample_rate} ${pulse_channels}"
  exec socat "tcp-listen:${tcp_port},bind=${tcp_bind},nodelay,reuseaddr,fork" "exec:${proxy_cmd},nofork"
}

if ! command -v socat >/dev/null 2>&1; then
  error 'socat not found. Is it installed?'
fi
if ! command -v gst-launch-1.0 >/dev/null 2>&1; then
  error 'GStreamer (gst-launch-1.0) not found. Is it installed?'
fi

if [ "$1" = 'proxy' ]; then
  shift
  proxy "$@"
else
  server "$@"
fi
