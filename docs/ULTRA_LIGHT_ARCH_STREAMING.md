# Ultra-Light Arch Browser Streaming (Golden Master)

This is the **production** RA2 streaming profile for the DS225+. See `docs/GOLDEN_MASTER.md` for the full locked descriptor.

## What runs inside the container

| Process | Purpose |
|---------|---------|
| PulseAudio | `game` null sink @ **48 kHz**; TCP capture |
| Xvfb | Headless X display (480p / 720p / 1080p tiers) |
| Openbox | Minimal window manager |
| `ra2-stream-gateway.py` | HTTPS + WSS on port `6080` (mapped to `6081`/`6082`) |
| `stream-helper` | GStreamer VA-API H.264/HEVC + Opus capture |
| Wine + RA2 | Game |

**Not running:** noVNC, x11vnc, websockify, Selkies, Wolf, Sunshine, WebRTC media.

## Browser support

| Browser | Support |
|---------|---------|
| Chromium / Chrome / Edge | **Primary** — WebCodecs H.264/HEVC + Opus + Web Audio |
| Safari | Not optimized |

## Deploy

```bash
cd /volume2/Data/App_Development/ra2-lan-party/project
cp .env.example .env   # set RA2_COMPOSE_ULTRA=1, serials, passwords, TLS
sh scripts/validate-env.sh
RA2_COMPOSE_ULTRA=1 sh scripts/redeploy-ultra.sh
```

Open:

```text
https://<NAS_LAN_IP>:6081/     # player 1
https://<NAS_LAN_IP>:6082/     # player 2
https://peterjfrancoiii2.synology.me:6081/   # remote (forward TCP 6081/6082)
```

Only ports **6081** and **6082** are required (HTTPS/WSS on the same port).

## Defaults (golden master)

| Setting | Value |
|---------|-------|
| Display | `960x720` @ 24-bit (`RESOLUTION` × `RA2_DISPLAY_DEPTH`) |
| In-game tiers | 640×480 / 960×720 / 1440×1080 |
| Video | H.265 10-bit VA-API @ **24 fps**, 900 kbps |
| Audio | Opus **48 kHz** end-to-end, 64 kbps, **20 ms** frames |
| Client | `SETTINGS_VERSION=18` — hard-refresh after upgrades |

**Enable audio:** click **Enable audio** or the connect overlay once per browser session.

## Transport settings menu

The browser client includes a collapsible **Transport** panel. Settings apply live over the existing WebSocket session (no reconnect).

| Setting | Options |
|---------|---------|
| Display tier | 480p / 720p / 1080p |
| Hardware encoder | H.265 10-bit (default), H.265 8-bit, H.264 |
| Video quality | low / balanced / sharp |
| Video bitrate | 300 kbps – 2.0 Mbps |
| Audio encoder | Opus (default), PCM fallback |
| Input polling | 60 / 125 / 200 Hz |

Tune in `.env`:

```bash
RA2_COMPOSE_ULTRA=1
WINE_VARIANT=amd64
WINE_ARCH=win32
RESOLUTION=960x720
RA2_DISPLAY_DEPTH=24
ULTRA_VIDEO_FPS=24
ULTRA_VIDEO_CODEC=H265_10
ULTRA_VIDEO_BITRATE=2000000
ULTRA_INPUT_MOVE_HZ=60
ULTRA_H265_TEST_ENABLED=1
ULTRA_GATEWAY_TLS=1
ULTRA_AUDIO_CODEC=opus
ULTRA_AUDIO_BITRATE=64000
ULTRA_AUDIO_FRAME_MS=20
ULTRA_AUDIO_RATE=48000
```

## Audio maintenance

After PulseAudio restarts or audio transport changes, Wine must reconnect:

```bash
sudo sh scripts/restart-audio-ultra.sh ra2-player-1
```

Verify Wine is feeding Pulse:

```bash
docker exec ra2-player-1 sh -lc 'PULSE_SERVER=unix:/tmp/pulse/native pactl list sink-inputs short'
```

## H.265 / HEVC

`ULTRA_H265_TEST_ENABLED=1` exposes HEVC in the transport menu. Verified on DS225+ (i965): Main and Main10 `EncSlice` entrypoints. Client degrades 10-bit → 8-bit HEVC → H.264 if decode fails.

Diagnostics when `ULTRA_VIDEO_DIAGNOSTICS=1`:

```text
/volume2/Data/App_Development/ra2-lan-party/logs/player1/video-diagnostics.log
```

## Verify

```bash
RA2_COMPOSE_ULTRA=1 sh scripts/check-ultra-ready.sh
python3 -m pytest tests/ -q
```

## Rollback

```bash
docker tag ra2-lan-party:ultra ra2-lan-party:ultra-prev   # before risky change
ULTRA_VIDEO_GPU_SCALE=0   # CPU convert without rebuild
```

Archived noVNC/WebRTC paths: `docs/ARCHIVED_EXPERIMENTS.md`.
