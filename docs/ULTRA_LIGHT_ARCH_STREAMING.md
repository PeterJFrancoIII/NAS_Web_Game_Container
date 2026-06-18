# Ultra-Light Arch Browser Streaming (Golden Master)

This is the **production** RA2 streaming profile for the DS225+. See `docs/GOLDEN_MASTER.md` and **`docs/GOLDEN_MASTER_UDP_LAN.md`** for locked descriptors.

## What runs inside the container

| Process | Purpose |
|---------|---------|
| PulseAudio | `game` null sink @ **48 kHz**; TCP capture |
| Xvfb | Headless X display (480p / 720p / 1080p tiers) |
| Openbox | Minimal window manager |
| `ra2-stream-gateway.py` | HTTPS + WSS on port `6080`; `/webrtc-signal` proxy |
| `stream-helper` | GStreamer VA-API H.264/HEVC + Opus (WSS fallback) |
| `webrtc-media.py` + helper | **WebRTC H.264 UDP video** (primary on LAN) |
| `RA2_Coturn` | TURN relay (host network) |
| Wine + games | RA2 / AoE2 / StarCraft |

**Not running:** noVNC, x11vnc, websockify, Selkies, Wolf, Sunshine.

## Browser support

| Browser | Support |
|---------|---------|
| Chromium / Chrome / Edge | **Primary** — WebCodecs + **WebRTC UDP** + Opus + Web Audio |
| Safari | Not optimized |

Transport settings are applied **live over the existing WebSocket** via `reconfigure` messages.

## Deploy

```bash
cd /volume2/Data/App_Development/ra2-lan-party/project
cp .env.example .env   # RA2_COMPOSE_ULTRA=1, RA2_COMPOSE_ULTRA_UDP=1, RA2_COMPOSE_ULTRA_UDP_HOST=1
sh scripts/validate-env.sh
RA2_COMPOSE_ULTRA=1 RA2_COMPOSE_ULTRA_UDP=1 RA2_COMPOSE_ULTRA_UDP_HOST=1 sh scripts/redeploy-ultra.sh
```

Open (LAN — verified UDP):

```text
https://192.168.0.193:6081/     # player 1 — prefer LAN IP for UDP
https://192.168.0.193:6082/     # player 2
```

Remote WSS works on DDNS; **remote UDP** requires router forwards for **62001–62020 UDP/TCP** and **5349 TCP**.

## UDP verification (transport panel)

After starting a game on LAN:

- `udp video: WebRTC verified`
- `webrtc rtp: N pkts` — N must increase
- `wss video rx: M (should stop increasing)` — M should freeze

## Defaults (golden master)

See `docs/GOLDEN_MASTER.md` §2.6. Client: **`SETTINGS_VERSION=49`**, `ultra-play.js?v=81`.

Default frame rate: **24 fps** (balanced preset).

## Verify

```bash
sh scripts/run-webrtc-tests.sh
RA2_COMPOSE_ULTRA=1 sh scripts/check-ultra-ready.sh
python3 -m pytest tests/ -q
ssh MediaServer2Local 'cd /volume2/Data/App_Development/ra2-lan-party/project && sh scripts/probe-webrtc-turn.sh'
```

If codec/VA-API capability probing fails, inspect `video-diagnostics.log` inside the player logs directory.

## Backup

```bash
NAS_HOST=MediaServer2Local sh scripts/backup-golden-master.sh
```

Label: **`golden-master-2026-06-udp-lan`**

Archived noVNC/Moonlight paths: `docs/ARCHIVED_EXPERIMENTS.md`.
