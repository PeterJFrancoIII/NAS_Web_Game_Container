#!/bin/sh
# Verify Tailscale is on a direct peer path (not DERP relay) before Moonlight latency tests.
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

TARGET="${1:-ra2-nas}"
WARN=0

warn() { printf 'WARN: %s\n' "$1"; WARN=1; }
ok() { printf 'OK: %s\n' "$1"; }
section() { printf '\n== %s ==\n' "$1"; }

section "Tailscale container"
state="$(container_status ra2-tailscale)"
if [ "$state" = "running" ]; then
  ok "ra2-tailscale is running"
else
  warn "ra2-tailscale state=${state:-not found} — start compose.tailscale.yaml with TAILSCALE_AUTHKEY"
fi

section "Local tailscale status"
if command -v tailscale >/dev/null 2>&1; then
  tailscale status 2>/dev/null || warn "tailscale status failed on host"
elif run_docker ps --format '{{.Names}}' 2>/dev/null | grep -qx ra2-tailscale; then
  run_docker exec ra2-tailscale tailscale status 2>/dev/null || warn "tailscale status failed in container"
else
  warn "tailscale CLI unavailable — install Tailscale on NAS or start ra2-tailscale"
fi

section "Direct path check"
if command -v tailscale >/dev/null 2>&1; then
  if tailscale ping -c 3 "$TARGET" 2>&1; then
    if tailscale ping -c 1 "$TARGET" 2>&1 | grep -qi 'via DERP'; then
      warn "Tailscale path to ${TARGET} uses DERP relay — forward UDP 41641 to NAS for direct P2P"
    else
      ok "Tailscale ping to ${TARGET} looks direct"
    fi
  else
    warn "tailscale ping to ${TARGET} failed"
  fi
elif run_docker ps --format '{{.Names}}' 2>/dev/null | grep -qx ra2-tailscale; then
  if run_docker exec ra2-tailscale tailscale ping -c 3 "$TARGET" 2>&1; then
    if run_docker exec ra2-tailscale tailscale ping -c 1 "$TARGET" 2>&1 | grep -qi 'via DERP'; then
      warn "Tailscale path to ${TARGET} uses DERP relay — forward UDP 41641 to NAS for direct P2P"
    else
      ok "Tailscale ping to ${TARGET} looks direct"
    fi
  else
    warn "tailscale ping to ${TARGET} failed from container"
  fi
fi

section "Network guidance"
printf '%s\n' \
  "- Forward external UDP 41641 → NAS LAN IP to improve direct WireGuard peering." \
  "- Do not expose GameStream ports (47984-48010) directly to the internet." \
  "- Connect Moonlight to the Tailscale IP of the NAS, not the public DDNS hostname." \
  "- Keep LAN Moonlight tests separate from remote Tailscale tests."

if [ "$WARN" -ne 0 ]; then
  printf '\nTailscale direct-path check completed with warnings.\n'
  exit 1
fi
printf '\nTailscale direct-path check passed.\n'
