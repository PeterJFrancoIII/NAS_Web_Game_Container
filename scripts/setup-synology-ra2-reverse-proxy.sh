#!/bin/sh
# Add a DSM reverse-proxy entry for remote RA2 ultra play over DDNS.
#
# Mirrors the existing qBittorrent pattern on this NAS:
#   https://ra2.<NAS_PUBLIC_HOSTNAME>:8443/  ->  https://127.0.0.1:6081/
#
# Prerequisites (DSM UI):
#   1. Control Panel -> Login Portal -> Advanced -> Reverse Proxy (script appends rule)
#   2. Control Panel -> External Access -> Router Configuration: allow TCP 8443
#   3. Certificate covering ra2.<your-ddns> (Let's Encrypt in DSM)
#
# Usage on the NAS:
#   sudo sh scripts/setup-synology-ra2-reverse-proxy.sh
#   sudo sh scripts/setup-synology-ra2-reverse-proxy.sh --dry-run
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$PROJECT_ROOT/.env}"

if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$SCRIPT_DIR/lib.sh" 2>/dev/null || true
  PUBLIC_HOST="$(read_env_value NAS_PUBLIC_HOSTNAME "" "$ENV_FILE")"
  PLAYER_PORT="$(read_env_value PLAYER1_HTTP_PORT 6081 "$ENV_FILE")"
else
  PUBLIC_HOST="${NAS_PUBLIC_HOSTNAME:-}"
  PLAYER_PORT="${PLAYER1_HTTP_PORT:-6081}"
fi

PUBLIC_HOST="${PUBLIC_HOST:-peterjfrancoiii2.synology.me}"
FRONTEND_HOST="${RA2_REVERSE_PROXY_HOST:-ra2.${PUBLIC_HOST}}"
FRONTEND_PORT="${RA2_REVERSE_PROXY_PORT:-8443}"
BACKEND_PORT="$PLAYER_PORT"
PROXY_FILE="${RA2_REVERSE_PROXY_FILE:-/usr/syno/etc/www/ReverseProxy.json}"
DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
fi

if [ ! -f "$PROXY_FILE" ]; then
  echo "Reverse proxy config not found: $PROXY_FILE" >&2
  exit 1
fi

python3 - "$PROXY_FILE" "$FRONTEND_HOST" "$FRONTEND_PORT" "$BACKEND_PORT" "$DRY_RUN" <<'PY'
import json, sys, uuid, copy, pathlib

path, frontend_host, frontend_port, backend_port, dry_run = sys.argv[1:6]
dry_run = dry_run == "1"
frontend_port = int(frontend_port)
backend_port = int(backend_port)

data = json.loads(pathlib.Path(path).read_text() or "{}")
if not isinstance(data, dict):
    raise SystemExit("invalid reverse proxy json")

for entry in data.values():
    if not isinstance(entry, dict):
        continue
    fe = entry.get("frontend") or {}
    be = entry.get("backend") or {}
    if fe.get("fqdn") == frontend_host and int(fe.get("port") or 0) == frontend_port:
        print(f"[ra2-proxy] rule already exists for https://{frontend_host}:{frontend_port}/")
        print(f"[ra2-proxy] backend https://127.0.0.1:{be.get('port', backend_port)}/")
        sys.exit(0)

entry_id = str(uuid.uuid4())
data[entry_id] = {
    "_key": str(uuid.uuid4()),
    "backend": {
        "fqdn": "127.0.0.1",
        "port": backend_port,
        "protocol": 1,
    },
    "customize_headers": [],
    "description": "RA2 Ultra Stream Player 1",
    "frontend": {
        "acl": None,
        "fqdn": frontend_host,
        "https": {"hsts": False},
        "port": frontend_port,
        "protocol": 0,
    },
    "proxy_connect_timeout": 3600,
    "proxy_http_version": 1,
    "proxy_intercept_errors": False,
    "proxy_read_timeout": 3600,
    "proxy_send_timeout": 3600,
}
data["version"] = 2
rendered = json.dumps(data, indent="\t") + "\n"

print(f"[ra2-proxy] frontend: https://{frontend_host}:{frontend_port}/")
print(f"[ra2-proxy] backend:  https://127.0.0.1:{backend_port}/")
if dry_run:
    print(rendered[:600] + "...")
    sys.exit(0)

src = pathlib.Path(path)
backup = src.with_suffix(src.suffix + ".bak-ra2")
if src.exists():
    backup.write_text(src.read_text())
src.write_text(rendered)
print(f"[ra2-proxy] wrote {path} (backup: {backup})")
PY

if [ "$DRY_RUN" = "1" ]; then
  exit 0
fi

if command -v synow3tool >/dev/null 2>&1; then
  synow3tool --nginx=reload || true
fi
if command -v nginx >/dev/null 2>&1; then
  nginx -s reload 2>/dev/null || true
fi

echo ""
echo "Remote play URL:"
echo "  https://${FRONTEND_HOST}:${FRONTEND_PORT}/"
echo ""
echo "If the link is still dead:"
echo "  1. DSM -> Control Panel -> Security -> Certificate -> add ${FRONTEND_HOST}"
echo "  2. DSM -> Control Panel -> External Access -> Router Configuration -> allow TCP ${FRONTEND_PORT}"
echo "  3. Ensure ra2-player-1 is running: docker ps | grep ra2-player-1"
