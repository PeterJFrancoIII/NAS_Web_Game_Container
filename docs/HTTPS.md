# HTTPS for Ultra Browser Play

The golden-master ultra client (`container/remote-ultra/`) requires a **secure context** (HTTPS or `localhost`) for WebCodecs, Web Audio, and WSS. Plain `http://` on ports 6081/6082 will not work reliably.

noVNC (archived base-image path) has the same secure-context requirement — see §Legacy noVNC below.

## Option A: In-container TLS (production default)

Best when players connect directly to NAS ports `6081` and `6082`.

### 1. Generate a self-signed certificate

On the NAS:

```bash
cd /volume2/Data/App_Development/ra2-lan-party/project
sh scripts/generate-tls-certs.sh
```

This writes `cert.pem` and `key.pem` under `TLS_DIR` (default: `../tls`). The certificate includes SANs for `NAS_HOSTNAME`, optional `NAS_PUBLIC_HOSTNAME`, `MediaServer2`, and `NAS_LAN_IP` from `.env`.

### 2. Start with HTTPS + ultra overlays

```bash
RA2_COMPOSE_ULTRA=1 docker compose --env-file .env \
  -f compose.yaml -f compose.https.yaml -f compose.ultra.yaml up -d
```

Or:

```bash
RA2_COMPOSE_ULTRA=1 sh scripts/redeploy-ultra.sh
```

### 3. Connect over HTTPS (ultra play page)

```text
Player 1 LAN:    https://192.168.0.193:6081/
Player 2 LAN:    https://192.168.0.193:6082/
Player 1 remote: https://peterjfrancoiii2.synology.me:6081/
Player 2 remote: https://peterjfrancoiii2.synology.me:6082/
```

Set `NAS_PUBLIC_HOSTNAME=peterjfrancoiii2.synology.me` in `.env`, regenerate TLS if the certificate predates the DDNS hostname, and forward TCP `6081`/`6082` on the router.

Browsers warn about the self-signed certificate. Trust it on each player machine, or use Option B.

### Verify

```bash
sudo sh scripts/verify-deployment.sh
RA2_COMPOSE_ULTRA=1 sh scripts/check-ultra-ready.sh
```

## Option B: Synology DSM reverse proxy (trusted certificate)

Optional trusted cert via `scripts/setup-synology-ra2-reverse-proxy.sh`:

```text
https://ra2.peterjfrancoiii2.synology.me:8443/
```

Requires TCP `8443` forward and a DSM certificate covering the subdomain. Production DDNS play on `:6081` does not need this.

Legacy path-based proxy example (noVNC era):

| Source | Destination |
|--------|-------------|
| `https://MediaServer2.local:443/ra2-p1` | `http://127.0.0.1:6081` |
| `https://MediaServer2.local:443/ra2-p2` | `http://127.0.0.1:6082` |

## Legacy noVNC (archived)

When `RA2_COMPOSE_ULTRA=0` and `RA2_ENABLE_NOVNC_FALLBACK=1`:

```text
Player 1: https://192.168.0.193:6081/vnc.html
Player 2: https://192.168.0.193:6082/vnc.html
```

noVNC 1.5+ shows **"noVNC requires a secure context (TLS). Expect crashes!"** over plain HTTP.

See `docs/ARCHIVED_EXPERIMENTS.md` for WebRTC and Moonlight TLS notes.
