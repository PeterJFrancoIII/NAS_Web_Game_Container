#!/bin/sh
# Keep coturn external-ip in sync with DDNS (Synology Task Scheduler or cron).
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${RA2_ENV_FILE:-$PROJECT_DIR/.env}"

read_env() {
  key="$1"
  default="${2:-}"
  if [ -f "$ENV_FILE" ]; then
    val="$(grep -E "^${key}=" "$ENV_FILE" | tail -n1 | cut -d= -f2- | tr -d '\r"'"'"'')"
    if [ -n "$val" ]; then
      printf '%s\n' "$val"
      return 0
    fi
  fi
  printf '%s\n' "$default"
}

CONFIG_PATH="${COTURN_CONFIG:-$SCRIPT_DIR/turnserver.conf}"
CONTAINER_NAME="${COTURN_CONTAINER:-RA2_Coturn}"
DDNS_DOMAIN="$(read_env NAS_PUBLIC_HOSTNAME peterjfrancoiii2.synology.me)"
INTERNAL_IP="$(read_env NAS_LAN_IP 192.168.0.193)"
DOCKER="${RA2_DOCKER:-/usr/local/bin/docker}"

if [ ! -f "$CONFIG_PATH" ]; then
  echo "$(date -Iseconds): missing config $CONFIG_PATH" >&2
  exit 1
fi

CURRENT_WAN_IP=""
if command -v dig >/dev/null 2>&1; then
  CURRENT_WAN_IP="$(dig +short "$DDNS_DOMAIN" A 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)"
fi
if [ -z "$CURRENT_WAN_IP" ] && command -v nslookup >/dev/null 2>&1; then
  CURRENT_WAN_IP="$(nslookup "$DDNS_DOMAIN" 2>/dev/null | awk '/^Address: / { print $2 }' | grep -E '^[0-9.]+$' | tail -n1 || true)"
fi
if [ -z "$CURRENT_WAN_IP" ]; then
  echo "$(date -Iseconds): failed to resolve $DDNS_DOMAIN" >&2
  exit 1
fi

EXPECTED_LINE="external-ip=${CURRENT_WAN_IP}/${INTERNAL_IP}"
CONFIGURED_LINE="$(grep -E '^external-ip=' "$CONFIG_PATH" | tail -n1 || true)"

if [ "$CONFIGURED_LINE" = "$EXPECTED_LINE" ]; then
  echo "$(date -Iseconds): WAN IP unchanged ($CURRENT_WAN_IP)"
  exit 0
fi

echo "$(date -Iseconds): updating coturn external-ip ($CONFIGURED_LINE -> $EXPECTED_LINE)"
cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"

if grep -q '^external-ip=' "$CONFIG_PATH"; then
  sed -i "s|^external-ip=.*|$EXPECTED_LINE|" "$CONFIG_PATH"
else
  printf '%s\n' "$EXPECTED_LINE" >> "$CONFIG_PATH"
fi

if "$DOCKER" inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  echo "$(date -Iseconds): restarting $CONTAINER_NAME"
  "$DOCKER" restart "$CONTAINER_NAME" >/dev/null
else
  echo "$(date -Iseconds): $CONTAINER_NAME not running; config updated only"
fi
