# Moonlight / Sunshine / Wolf Experiment (DS225+)

> **Archived (June 2026):** Production play uses ultra browser streaming. See `docs/GOLDEN_MASTER.md` and `docs/ARCHIVED_EXPERIMENTS.md`. This document is kept for experiment reference only.

This was the **target native streaming path** for low-latency play. The existing RA2 player containers (`ra2-player-1/2`) remain unchanged; Moonlight experiments run **beside** them until validation completes.

## Why Moonlight?

Research on DS225+ (Intel J4125 / UHD 600) shows Moonlight + Sunshine/Wolf delivers 10–20 ms LAN latency with VA-API H.264/HEVC hardware encode — far below browser WebRTC over `ximagesrc`. WebRTC and noVNC remain **fallback/admin** paths only.

## Prerequisites

Run before any Moonlight experiment:

```bash
sh scripts/check-host-prerequisites.sh
sh scripts/check-moonlight-ready.sh
```

Hard requirements:

- `/dev/dri/renderD128` with H.264 and HEVC VA-API profiles (`scripts/check-transcode.sh`)
- `/dev/uinput` loaded (manual: `scripts/prepare-streaming-session.sh`; boot task deferred)
- **6 GB RAM** production baseline (1.7 GB stock RAM is fallback/testing only)
- Wired **2.5GbE or 1GbE** for latency measurements

## Experiment A: Sunshine (smallest moving part)

```bash
cd /volume2/Data/App_Development/ra2-lan-party/project
mkdir -p data/sunshine-experiment/config
docker compose --env-file .env -f compose.sunshine.yaml up -d
```

Sunshine uses **host networking** and GameStream ports:

- TCP `47984-47990`, `48010`
- UDP `47998-48000`

Open the Sunshine web UI (default `https://<NAS_LAN_IP>:47990`), set credentials, then pair the **Moonlight** client.

**Caveat:** Sunshine still needs a display surface. RA2 runs in separate Xvfb containers today, so Sunshine alone may not capture the game desktop until Wolf or a shared display bridge is proven.

## Experiment B: Wolf (preferred architecture)

Wolf (Games on Whales) spins up Wayland child containers on demand with `inputtino` virtual input — the research-preferred path for headless NAS.

```bash
mkdir -p data/wolf-experiment/config
docker compose --env-file .env -f compose.wolf.yaml up -d
```

Wolf requires:

- Docker socket access (`/var/run/docker.sock`)
- Host networking
- `/dev/dri/renderD128` and `/dev/uinput`

Pair Moonlight to the NAS LAN IP (or Tailscale IP for remote tests).

### Wolf pairing (current PoC)

Wolf is running when `ra2-wolf-experiment` is Up. GameStream ports:

| Port | Protocol | Purpose |
|------|----------|---------|
| 47984 | HTTPS | Pairing / control |
| 47989 | HTTP | Auxiliary |
| 48010 | TCP | RTSP |
| 47999 | UDP | Control/media |

**Moonlight app steps (LAN):**

1. Open Moonlight on your Mac/iPad/phone (same network as NAS).
2. Tap **Add PC** (or **+**).
3. Enter NAS IP: `192.168.0.193` (or your `NAS_LAN_IP`).
4. Moonlight shows a PIN — approve it in Wolf logs:

```bash
sudo docker logs -f ra2-wolf-experiment
```

5. After pairing, select a Wolf app/desktop from the Moonlight list.

Wolf logs should show `Using h264 encoder: qsv` and `Using zero copy pipeline on Intel` — that confirms hardware encode.

**Known limitation:** `/dev/uinput` is not loaded yet, so video may work before keyboard/mouse do. Install `uinput.ko` when ready.

## Compare against WebRTC fallback

```bash
sh scripts/compare-moonlight-webrtc.sh
```

| Metric | WebRTC (`remote.html`) | Moonlight |
|--------|------------------------|-----------|
| Glass-to-glass latency | click-to-pixel | same method |
| Encode path | `vah264enc` + `ximagesrc` | VA-API direct |
| Client | Browser | Moonlight app |
| Remote access | DDNS + port forwards | Tailscale direct |
| Admin/debug | noVNC `vnc.html` | noVNC `vnc.html` |

## Go / no-go criteria

Promote Moonlight to production primary only when **all** are true on DS225+ hardware:

1. Moonlight pairs and streams with VA-API encode (not software fallback).
2. RA2 display session is visible and controllable.
3. Measured latency is lower than stable H.264 WebRTC.
4. CPU/RAM stay within limits at 6 GB RAM.
5. Remote play works over **Tailscale direct** path (not DERP).

Until then, use noVNC for admin/recovery and WebRTC only as an optional legacy path.

## Rollback

```bash
docker compose --env-file .env -f compose.sunshine.yaml down
docker compose --env-file .env -f compose.wolf.yaml down
```

RA2 players are unaffected.
