# Consolidated Architecture (DS225+ Implementation Map)

This project implements the consolidated research at:

`Research/Consolidated_Remote Desktop, Cloud Gaming, and Web Rendering Architecture for Synology DS225+.md`

**Golden master (June 2026):** Profile 0 — Ultra Arch browser streaming. See `docs/GOLDEN_MASTER.md`.

## Build profiles

| Profile | Stack | Status | Compose / script |
|---------|-------|--------|------------------|
| **0 — Browser (production)** | Ultra Arch + WSS/WebCodecs | **Golden master** | `compose.ultra.yaml`, `scripts/redeploy-ultra.sh` |
| 1 — Native Moonlight | Wolf + Moonlight | Archived | `compose.wolf.yaml`, `docs/ARCHIVED_EXPERIMENTS.md` |
| 1b — Sunshine | Sunshine + Moonlight | Archived | `compose.sunshine.yaml` |
| RA2 game core | Wine + Xvfb | Production (inside ultra) | `compose.yaml` |
| Admin noVNC | noVNC + websockify | Archived | base `compose.yaml` without ultra |
| Legacy WebRTC | `remote.html` | Archived | `compose.webrtc.yaml` |
| Selkies/Webtop | Full desktop | Rejected | `compose.selkies-experiment.yaml` |
| WAN Tailscale | Remote Moonlight | Archived | `compose.tailscale.yaml` |

## Production deployment order

1. Copy project to `/volume2/Data/App_Development/ra2-lan-party/project`
2. `sh scripts/prepare-nas.sh` and copy game assets
3. `cp .env.example .env` — set `RA2_COMPOSE_ULTRA=1`, serials, TLS, DDNS hostname
4. `sh scripts/validate-env.sh`
5. `sh scripts/generate-tls-certs.sh` (if needed)
6. `RA2_COMPOSE_ULTRA=1 sh scripts/redeploy-ultra.sh`
7. Play at `https://<NAS>:6081/` — enable audio, hard-refresh after client updates

## Host requirements

| Requirement | Check |
|-------------|-------|
| `/dev/dri/renderD128` | `sh scripts/check-transcode.sh` |
| VA-API H.264/HEVC | `vainfo` inside container |
| TLS for browser | `docs/HTTPS.md` |
| Router forwards | TCP `6081-6082` for DDNS play |

uinput and Moonlight host prep are only needed for archived native streaming experiments.

## Port reference

| Service | Ports | Exposure |
|---------|-------|----------|
| **RA2 ultra browser (production)** | 6081-6082 TCP HTTPS/WSS | LAN / DDNS |
| RA2 noVNC (archived) | 6081-6082 `/vnc.html` | Not used in ultra |
| WebRTC (archived) | 6083-6086 TCP, 62001-62040 UDP/TCP | Fallback only |
| GameStream Wolf/Sunshine (archived) | 47984-48010 | LAN/VPN only |
| Optional DSM reverse proxy | 8443 TCP | `setup-synology-ra2-reverse-proxy.sh` |

## Diagnostics

```bash
RA2_COMPOSE_ULTRA=1 sh scripts/check-ultra-ready.sh
sudo sh scripts/restart-audio-ultra.sh ra2-player-1
sudo sh scripts/cleanup-golden-master.sh
```

Archived experiment checks: `check-moonlight-ready.sh`, `check-webrtc-ice-reachability.sh`.
