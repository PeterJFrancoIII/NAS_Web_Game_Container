# Ultra-Light Arch Browser Streaming (Primary Browser Path)

This is the **recommended browser-only** RA2 streaming profile for the DS225+. It replaces the heavy Webtop/Selkies sidecar with a minimal Arch container that runs only what RA2 needs.

## What runs inside the container

| Process | Purpose |
|---------|---------|
| PulseAudio | Game audio capture |
| Xvfb | Headless X display for Wine |
| Openbox | Minimal window manager |
| `ra2-stream-gateway.py` | HTTPS + WSS on one port |
| `stream-helper` | GStreamer VAAPI H.264 + raw PCM capture |
| Wine + RA2 | Game |

**Not running:** noVNC, x11vnc, websockify, Selkies, Wolf, Sunshine, XFCE/KDE.

## Browser support

| Browser | Support |
|---------|---------|
| Chromium / Chrome / Edge | **Primary** — WebCodecs H.264 + WebCodecs Opus/Web Audio |
| Safari | Not optimized (use noVNC/WebRTC fallback) |

## Deploy

```bash
cd /volume2/Data/App_Development/ra2-lan-party/project
cp .env.example .env   # if needed
# Set PLAYER1_SERIAL, PLAYER2_SERIAL, passwords, TLS paths
RA2_COMPOSE_ULTRA=1 sh scripts/redeploy-ultra.sh
```

Open:

```text
https://<NAS_LAN_IP>:6081/     # player 1
https://<NAS_LAN_IP>:6082/     # player 2
```

Only ports **6081** and **6082** are required for browser play (HTTPS/WSS on the same port). No WebRTC media port range needed.

## Defaults

- Resolution: 1024×768
- Video: H.264 VAAPI @ **24 fps**
- Audio: Opus @ **96 kbps** by default, sourced from 44.1 kHz game audio and packetized at Opus' 48 kHz transport rate; PCM remains an optional fallback
- Input: xdotool over WSS (same event schema as WebRTC input proxy)

## Transport settings menu

The browser client includes a collapsible **Transport** panel (top-left). Settings are staged locally and **apply on reconnect** so gameplay stays stable mid-session.

| Setting | Options |
|---------|---------|
| Video quality | `low` (20 fps), `balanced` (24 fps), `sharp` (24 fps, higher bitrate) |
| Hardware encoder | H.264 VAAPI (default), H.265 if server hardware supports it |
| Audio encoder | Opus low-latency (default), PCM fallback |
| Audio quality | 64 / 96 / 128 kbps plus 44.1 kHz or 48 kHz source audio |
| Input polling | 60 / 125 / 200 Hz mouse move rate |

The gateway returns `hello.available`, `ready.active`, `ready.requested`, and `ready.fallbacks` so the status panel shows what is actually running versus what was requested.

Tune in `.env`:

```bash
ULTRA_VIDEO_FPS=24
ULTRA_VIDEO_CODEC=H264
ULTRA_VIDEO_BITRATE=900000
ULTRA_GATEWAY_TLS=1
ULTRA_AUDIO_CODEC=opus
ULTRA_AUDIO_BITRATE=96000
ULTRA_AUDIO_RATE=44100
ULTRA_AUDIO_TRANSPORT_RATE=48000
```

H.265 is optional in the transport menu only when the NAS reports a hardware HEVC encoder **and** the browser accepts the codec. If unavailable, the gateway falls back to H.264 and reports the reason in `ready.fallbacks`.

## Verify

```bash
RA2_COMPOSE_ULTRA=1 sh scripts/check-ultra-ready.sh
```

## Why Selkies was rejected

Selkies/Webtop pulls a full desktop stack (XFCE, nginx, Selkies, GPU compositor) beside RA2. On a 1.7 GB DS225+ this causes swap pressure, capture restart loops, and "waiting for stream" failures. The ultra profile keeps the RA2 runtime lean and streams directly from the existing Xvfb session.

## Rollback

```bash
RA2_COMPOSE_ULTRA=0
docker compose --env-file .env -f compose.yaml -f compose.https.yaml up -d --force-recreate ra2-player-1
```

Browser admin fallback: `https://<NAS>:6081/vnc.html` (standard noVNC profile).

## Diagnostics

```bash
docker logs ra2-player-1
docker exec ra2-player-1 pgrep -af 'stream|gateway|Xvfb|wine'
RA2_COMPOSE_ULTRA=1 sh scripts/check-ultra-ready.sh
```
