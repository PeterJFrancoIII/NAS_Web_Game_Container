#!/bin/sh
# Start Moonlight side-by-side experiments (Sunshine and/or Wolf) without touching ra2-player-1/2.
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

COMPOSE_DIR="${COMPOSE_DIR:-/volume2/Data/App_Development/ra2-lan-party/project}"
ENV_FILE="${ENV_FILE:-$COMPOSE_DIR/.env}"
MODE="${1:-wolf}"
NAS_IP="$(read_env_value NAS_LAN_IP 192.168.0.193 "$ENV_FILE")"

cd "$COMPOSE_DIR"
mkdir -p data/sunshine-experiment/config data/wolf-experiment/config

printf '== Session prep ==\n'
RA2_PREREQ_WARN_ONLY=1 sh "$SCRIPT_DIR/prepare-streaming-session.sh" || true

compose_args="-f compose.yaml"
case "$MODE" in
  sunshine)
    compose_args="-f compose.sunshine.yaml"
    service="ra2-sunshine-experiment"
  ;;
  wolf)
    compose_args="-f compose.wolf.yaml"
    service="ra2-wolf-experiment"
  ;;
  both)
    compose_args="-f compose.sunshine.yaml -f compose.wolf.yaml"
    service="ra2-wolf-experiment ra2-sunshine-experiment"
  ;;
  *)
    echo "Usage: sh scripts/redeploy-moonlight-poc.sh [sunshine|wolf|both]"
    exit 1
  ;;
esac

if [ "${RA2_COMPOSE_MOONLIGHT_UINPUT:-0}" = "1" ] && [ -f compose.moonlight-uinput.yaml ]; then
  compose_args="$compose_args -f compose.moonlight-uinput.yaml"
fi

printf '\n== Starting Moonlight experiment(s): %s ==\n' "$MODE"
# shellcheck disable=SC2086
run_docker compose --env-file "$ENV_FILE" $compose_args up -d --force-recreate $service

printf '\n== Moonlight readiness ==\n'
sh "$SCRIPT_DIR/check-moonlight-ready.sh" || true

printf '\n== Pair Moonlight (LAN) ==\n'
if [ "$MODE" = "wolf" ] || [ "$MODE" = "both" ]; then
  printf '  Wolf HTTPS (pairing): https://%s:47984\n' "$NAS_IP"
  printf '  RTSP: %s:48010  |  Control UDP: 47999\n' "$NAS_IP"
  printf '  In Moonlight: Add PC -> enter %s -> enter PIN shown in Wolf logs:\n' "$NAS_IP"
  printf '    sudo docker logs -f ra2-wolf-experiment\n'
fi
if [ "$MODE" = "sunshine" ] || [ "$MODE" = "both" ]; then
  printf '  Sunshine web UI: https://%s:47990\n' "$NAS_IP"
fi
printf '\nRA2 admin fallback: https://%s:6081/vnc.html\n' "$NAS_IP"
printf 'See docs/MOONLIGHT_EXPERIMENT.md\n'
