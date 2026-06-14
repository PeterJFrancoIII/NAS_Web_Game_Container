#!/bin/sh
set -eu

if [ "${RA2_ENABLE_LATENCY_PROXY:-1}" = "0" ]; then
  printf '[latency-proxy] disabled (RA2_ENABLE_LATENCY_PROXY=0)\n' >&2
  exit 0
fi

readonly SCRIPT="$0"
readonly TCP_BIND='127.0.0.1'
readonly DEFAULT_PORT='5721'

print_usage() {
  echo "Usage: ${SCRIPT} [-l port] [-b bind-host]"
  echo "Latency echo probe for the noVNC browser overlay"
}

probe_session() {
  while IFS= read -r line; do
    case "$line" in
      PING:*)
        client_sent="${line#PING:}"
        server_seen="$(date +%s%3N 2>/dev/null || python - <<'PY'
import time
print(int(time.time() * 1000))
PY
)"
        printf 'PONG:%s:%s\n' "$client_sent" "$server_seen"
        ;;
      *)
        printf 'ERR:bad-probe\n'
        ;;
    esac
  done
}

server() {
  tcp_port="${DEFAULT_PORT}"
  tcp_bind="${TCP_BIND}"

  while getopts 'l:b:h' opt; do
    case "${opt}" in
      l) tcp_port="${OPTARG}" ;;
      b) tcp_bind="${OPTARG}" ;;
      h)
        print_usage
        exit 0
        ;;
      *)
        print_usage >&2
        exit 1
        ;;
    esac
  done

  if ! command -v socat >/dev/null 2>&1; then
    echo 'socat not found. Is it installed?' >&2
    exit 1
  fi

  echo "Latency probe listening on ${tcp_bind}:${tcp_port}"
  exec socat "tcp-listen:${tcp_port},bind=${tcp_bind},nodelay,reuseaddr,fork" "exec:/bin/sh ${SCRIPT} session,nofork"
}

case "${1:-server}" in
  session)
    probe_session
    ;;
  server)
    shift || true
    server "$@"
    ;;
  *)
    server "$@"
    ;;
esac
