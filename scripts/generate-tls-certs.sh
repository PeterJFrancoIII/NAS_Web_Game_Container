#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

COMPOSE_DIR="${COMPOSE_DIR:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}"
ENV_FILE="${ENV_FILE:-$COMPOSE_DIR/.env}"

if [ -f "$ENV_FILE" ]; then
  TLS_DIR="$(read_env_value TLS_DIR /volume2/Data/App_Development/ra2-lan-party/tls "$ENV_FILE")"
  NAS_HOSTNAME="$(read_env_value NAS_HOSTNAME MediaServer2.local "$ENV_FILE")"
  NAS_LAN_IP="$(read_env_value NAS_LAN_IP 192.168.0.193 "$ENV_FILE")"
  NAS_PUBLIC_HOSTNAME="$(read_env_value NAS_PUBLIC_HOSTNAME "" "$ENV_FILE")"
else
  TLS_DIR="${TLS_DIR:-/volume2/Data/App_Development/ra2-lan-party/tls}"
  NAS_HOSTNAME="${NAS_HOSTNAME:-MediaServer2.local}"
  NAS_LAN_IP="${NAS_LAN_IP:-192.168.0.193}"
  NAS_PUBLIC_HOSTNAME="${NAS_PUBLIC_HOSTNAME:-}"
fi

CERT="${TLS_DIR}/cert.pem"
KEY="${TLS_DIR}/key.pem"
OPENSSL_CNF="$(mktemp)"
trap 'rm -f "$OPENSSL_CNF"' EXIT

mkdir -p "$TLS_DIR"
chmod 755 "$TLS_DIR"

cat >"$OPENSSL_CNF" <<EOF
[req]
default_bits = 4096
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_req

[dn]
CN = ${NAS_HOSTNAME}

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${NAS_HOSTNAME}
EOF

san_index=2
if [ -n "$NAS_PUBLIC_HOSTNAME" ]; then
  printf 'DNS.%s = %s\n' "$san_index" "$NAS_PUBLIC_HOSTNAME" >>"$OPENSSL_CNF"
  san_index=$((san_index + 1))
fi
printf 'DNS.%s = MediaServer2\n' "$san_index" >>"$OPENSSL_CNF"
printf 'IP.1 = %s\n' "$NAS_LAN_IP" >>"$OPENSSL_CNF"

if [ -f "$CERT" ] && [ -f "$KEY" ]; then
  printf 'TLS certificate already exists:\n  %s\n  %s\n' "$CERT" "$KEY"
  printf 'Delete them first if you need to regenerate.\n'
  exit 0
fi

openssl req -x509 -nodes -days 825 -newkey rsa:4096 \
  -keyout "$KEY" \
  -out "$CERT" \
  -config "$OPENSSL_CNF" \
  -extensions v3_req

fix_tls_permissions "$ENV_FILE"

cat <<EOF
Generated self-signed TLS certificate for noVNC:

  Certificate: $CERT
  Private key: $KEY
  Hostname:    $NAS_HOSTNAME
  Public host: ${NAS_PUBLIC_HOSTNAME:-not configured}
  LAN IP SAN:  $NAS_LAN_IP

Browsers will warn about the self-signed certificate until you trust it.
For a trusted cert on Synology, see docs/HTTPS.md (DSM reverse proxy).

Start with HTTPS:

  cd $COMPOSE_DIR
  docker compose --env-file .env -f compose.yaml -f compose.https.yaml up -d

Connect:

  Player 1 LAN: https://${NAS_LAN_IP}:6081/vnc.html
  Player 2 LAN: https://${NAS_LAN_IP}:6082/vnc.html
EOF
if [ -n "$NAS_PUBLIC_HOSTNAME" ]; then
  cat <<EOF
  Player 1 remote: https://${NAS_PUBLIC_HOSTNAME}:6081/vnc.html
  Player 2 remote: https://${NAS_PUBLIC_HOSTNAME}:6082/vnc.html
EOF
fi
