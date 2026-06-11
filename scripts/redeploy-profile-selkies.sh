#!/bin/sh
# Profile 2: browser-native Selkies/Webtop experiment (side-by-side with RA2 players).
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

COMPOSE_DIR="${COMPOSE_DIR:-/volume2/Data/App_Development/ra2-lan-party/project}"
ENV_FILE="${ENV_FILE:-$COMPOSE_DIR/.env}"

cd "$COMPOSE_DIR"
mkdir -p data/selkies-experiment/config

export RA2_COMPOSE_SELKIES=1

printf '== Host prerequisites (warn-only) ==\n'
RA2_PREREQ_WARN_ONLY=1 sh "$SCRIPT_DIR/check-host-prerequisites.sh" || true

printf '\n== Starting Selkies experiment ==\n'
run_compose "$ENV_FILE" up -d

printf '\nBrowser URL (HTTPS):\n'
nas_ip="$(read_env_value NAS_LAN_IP 192.168.0.193 "$ENV_FILE")"
port="$(read_env_value SELKIES_HTTPS_PORT 6101 "$ENV_FILE")"
printf '  https://%s:%s\n' "$nas_ip" "$port"
printf '\nSee docs/SELKIES_EXPERIMENT.md\n'
