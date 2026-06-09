# HTTPS for noVNC and Browser Audio

noVNC 1.5+ requires a **secure context** (HTTPS or `localhost`). Over plain HTTP the browser blocks `crypto.subtle` and other APIs the client uses for VNC authentication and the audio plugin. You will see:

```text
noVNC requires a secure context (TLS). Expect crashes!
```

Audio WebSockets also need **WSS** when the page is served over HTTPS.

This project supports two ways to get TLS.

## Option A: In-container TLS (quick LAN setup)

Best when players connect directly to NAS ports `6081` and `6082`.

### 1. Generate a self-signed certificate

On the NAS:

```bash
cd /volume2/Data/App_Development/ra2-lan-party/project
sh scripts/generate-tls-certs.sh
```

This writes `cert.pem` and `key.pem` under `TLS_DIR` (default: `../tls`). The certificate includes SANs for `NAS_HOSTNAME`, optional `NAS_PUBLIC_HOSTNAME`, `MediaServer2`, and `NAS_LAN_IP` from `.env`.

### 2. Start with the HTTPS overlay

```bash
docker compose --env-file .env -f compose.yaml -f compose.https.yaml up -d
```

### 3. Connect over HTTPS

```text
Player 1: https://192.168.0.193:6081/vnc.html
Player 2: https://192.168.0.193:6082/vnc.html
```

For remote access through Synology DDNS, set `NAS_PUBLIC_HOSTNAME=peterjfrancoiii2.synology.me` in `.env`, regenerate TLS if the certificate already existed, and connect through the forwarded player ports:

```text
Player 1: https://peterjfrancoiii2.synology.me:6081/vnc.html
Player 2: https://peterjfrancoiii2.synology.me:6082/vnc.html
```

Browsers will warn about the self-signed certificate. Trust it on each player machine, or use Option B for a DSM-managed certificate.

### Verify

```bash
sudo sh scripts/verify-deployment.sh
```

URLs in the output should use `https://` when certificates are present.

## Option B: Synology DSM reverse proxy (trusted certificate)

Best when you already use DSM **Control Panel → Login Portal → Advanced → Reverse Proxy** with a Let's Encrypt or imported certificate.

### Example rules

| Source | Destination |
|--------|-------------|
| `https://MediaServer2.local:443/ra2-p1` | `http://127.0.0.1:6081` |
| `https://MediaServer2.local:443/ra2-p2` | `http://127.0.0.1:6082` |

Enable **HSTS** only if you understand the implications. Synology forwards WebSocket upgrades automatically for noVNC and audio.

Keep the base stack on HTTP inside Docker; the browser sees HTTPS and noVNC enables encrypted WebSockets (`wss://`) to the reverse proxy, which proxies to websockify as plain `ws://` on localhost.

Connect:

```text
Player 1: https://MediaServer2.local/ra2-p1/vnc.html
Player 2: https://MediaServer2.local/ra2-p2/vnc.html
```

Do **not** change the URL to `https://192.168.0.193:6081` unless you also enable Option A — changing only the scheme without TLS on websockify will fail.

## What changes in the container

- `container/start-websockify.sh` adds `--cert` and `--key` when `/opt/ra2/tls/cert.pem` exists.
- `compose.https.yaml` bind-mounts `TLS_DIR` at `/opt/ra2/tls`.
- Health checks and `verify-deployment.sh` probe HTTPS when certificates are mounted.

Without certificates, the stack still starts but logs a warning and serves plain HTTP (not recommended).

## Firewall and DDNS Routing

Allow the same TCP ports as before (`6081`, `6082`) for Option A, or HTTPS (`443`) for Option B. For DDNS access with Option A, configure your router and DSM firewall so:

- External TCP `6081` forwards to NAS `192.168.0.193:6081` for Player 1.
- External TCP `6082` forwards to NAS `192.168.0.193:6082` for Player 2.
- The remote browser uses `https://peterjfrancoiii2.synology.me:6081/vnc.html` or `:6082`.

Do not expose these ports to the public internet without strong VNC passwords and, ideally, a VPN or DSM reverse proxy with additional access controls.
