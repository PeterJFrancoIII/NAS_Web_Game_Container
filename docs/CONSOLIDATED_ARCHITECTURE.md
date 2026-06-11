# Consolidated Architecture (DS225+ Implementation Map)

This project implements the consolidated research at:

`Research/Consolidated_Remote Desktop, Cloud Gaming, and Web Rendering Architecture for Synology DS225+.md`

## Build profiles

| Profile | Stack | When to use | Compose / script |
|---------|-------|-------------|------------------|
| **0 — Browser (primary)** | Ultra Arch + WSS/WebCodecs | Zero-install browser play in Chromium | `compose.ultra.yaml`, `scripts/redeploy-ultra.sh` |
| **1 — Primary native** | Wolf + Moonlight | Lowest latency, native clients | `compose.wolf.yaml`, `scripts/redeploy-moonlight-poc.sh wolf` |
| **1b — Secondary native** | Sunshine + Moonlight | Simpler single host (headless caveats) | `compose.sunshine.yaml` |
| **RA2 game** | Wine + Xvfb | Two-player LAN party core | `compose.yaml` |
| **Admin** | noVNC | Recovery / debugging | `compose.yaml` + `compose.https.yaml` |
| **Legacy** | WebRTC `remote.html` | Browser fallback only | `compose.webrtc.yaml` |
| **Rejected** | Selkies/Webtop | Too heavy for DS225+ | `compose.selkies-experiment.yaml` (experiment only) |
| **WAN** | Tailscale | Remote Moonlight without public GameStream ports | `compose.tailscale.yaml`, `docs/TAILSCALE.md` |

## Implementation order (from research §16)

1. Upgrade RAM to **6 GB** (`RA2_PRODUCTION_RAM_MIB=6144`).
2. Use **2.5GbE** for streaming traffic.
3. Run host prep: `sh scripts/check-host-prerequisites.sh`
4. **Manual session prep** (no DSM boot task for now): `sudo sh scripts/prepare-streaming-session.sh`
5. Restore i915/QSV if needed: `sudo sh scripts/enable-host-transcode.sh`
6. Deploy Wolf: `sudo sh scripts/redeploy-moonlight-poc.sh wolf`
7. Pair Moonlight on LAN; validate H.264 + input.
8. Add Tailscale for WAN: `docs/TAILSCALE.md`
9. Deploy ultra browser profile: `RA2_COMPOSE_ULTRA=1 sh scripts/redeploy-ultra.sh`

_Deferred:_ DSM boot task (`scripts/dsm-boot-task.sh`) — add later when you want permissions to survive reboot.

## Host requirements (non-negotiable)

| Requirement | Check |
|-------------|-------|
| `/dev/dri/renderD128` | `sh scripts/check-transcode.sh` |
| `/dev/uinput` | `sh scripts/enable-uinput.sh` |
| VA-API H.264/HEVC | `vainfo` inside container |
| 6 GB RAM production | `sh scripts/check-host-prerequisites.sh` |
| Session DRI/uinput prep | `sudo sh scripts/prepare-streaming-session.sh` |
| Boot-time persistence (deferred) | `scripts/dsm-boot-task.sh` in DSM Task Scheduler |

Enable uinput device passthrough when `/dev/uinput` exists:

```bash
RA2_COMPOSE_MOONLIGHT_UINPUT=1 sh scripts/redeploy-moonlight-poc.sh wolf
```

## Port reference

| Service | Ports | Exposure |
|---------|-------|----------|
| RA2 ultra browser | 6081-6082 TCP (HTTPS/WSS) | LAN / DDNS |
| RA2 noVNC admin | 6081-6082 TCP `/vnc.html` | LAN / admin |
| WebRTC legacy | 6083-6086 TCP, 62001-62040 UDP/TCP | Fallback only |
| GameStream (Wolf/Sunshine) | 47984-47990 TCP, 47998-48000 UDP, 48010 | **LAN/VPN only** |
| Selkies | 6100 HTTP, 6101 HTTPS | LAN or reverse proxy |
| Tailscale P2P | 41641 UDP | Router forward to NAS |

## RA2 + Wolf coexistence

`ra2-player-1/2` remain the Wine/RA2 game hosts. Wolf runs **beside** them for streaming experiments. Full integration (streaming the RA2 Xvfb desktop through Wolf) is a future validation step — start with Wolf's test desktop before attaching RA2.

## Diagnostics

```bash
sh scripts/check-moonlight-ready.sh
sh scripts/check-tailscale-direct.sh
sh scripts/compare-moonlight-webrtc.sh
sh scripts/check-webrtc-ice-reachability.sh   # legacy WebRTC only
```
