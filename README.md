# Synology RA2 Arch LAN Party

This project prepares a Synology DS225+ to host two Red Alert 2 / Yuri's Revenge game instances in lightweight Arch Linux Docker containers. Each player connects over the network while the game instances see each other on a static private Docker LAN.

**Golden master:** read `docs/GOLDEN_MASTER.md` before changing the ultra streaming runtime, Wine architecture, input forwarding, or CPU affinity.

## Streaming architecture

| Path | Role | Client |
|------|------|--------|
| **Ultra Arch Browser** | Primary browser play (single-port WSS/WebCodecs) | Chromium `https://NAS:6081/` |
| **Moonlight + Sunshine/Wolf** | Lowest latency native play | Moonlight app |
| **noVNC** | Admin, recovery, debugging | Browser `vnc.html` |
| **WebRTC** | Legacy browser fallback | Browser `remote.html` |

See `docs/ULTRA_LIGHT_ARCH_STREAMING.md` for the ultra-light browser profile and `docs/MOONLIGHT_EXPERIMENT.md` for Moonlight.

**Production baseline:** upgrade the DS225+ to **6 GB RAM** before treating Moonlight or stable two-player play as production-ready (stock 1.7 GB is fallback/testing only).

## What It Builds

- `ra2-player-1`: Arch Linux + Wine + Xvfb/noVNC, internal IP `172.22.20.11`, browser port `6081`.
- `ra2-player-2`: Arch Linux + Wine + Xvfb/noVNC, internal IP `172.22.20.12`, browser port `6082`.
- Optional side-by-side Moonlight experiments: `compose.sunshine.yaml`, `compose.wolf.yaml`.
- Shared read-only assets folder for legal game files.
- Separate persistent Wine prefixes for each player.

The runtime avoids full VMs and desktop environments. It uses `Xvfb`, `openbox`, `x11vnc`, `websockify`, and noVNC for admin/recovery while Moonlight becomes the performance target.

## Replicable Ultra Container Build

The golden-master browser path is built from `container/Dockerfile.ultra` and launched with `compose.yaml`, `compose.https.yaml`, and `compose.ultra.yaml`. The intended image tag is:

```text
ra2-lan-party:ultra
```

Build command:

```bash
docker compose --env-file .env -f compose.yaml -f compose.https.yaml -f compose.ultra.yaml build ra2-player-1 ra2-player-2
```

Launch command:

```bash
RA2_COMPOSE_ULTRA=1 docker compose --env-file .env -f compose.yaml -f compose.https.yaml -f compose.ultra.yaml up -d
```

Dockerfile base and build arguments:

```text
Builder image: archlinux:latest
Runtime image: archlinux:latest
Dockerfile: container/Dockerfile.ultra
WINE_BUILD=10.8
WINE_VARIANT=amd64
WINE_ARCH=win32
WINE_ENABLE_MULTILIB=1
Wine tarball: https://github.com/Kron4ek/Wine-Builds/releases/download/${WINE_BUILD}/wine-${WINE_BUILD}-${WINE_VARIANT}.tar.xz
```

The image uses the `amd64` Wine package with a `win32` prefix. Keep that pairing unless a replacement is proven under live gameplay; the game is 32-bit, and a 64-bit prefix is not part of the stable runtime.

Builder packages:

```text
ca-certificates curl gcc git gstreamer gst-plugins-base pkgconf tar xz
gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav gst-plugin-va
```

Runtime packages:

```text
alsa-lib alsa-plugins alsa-utils ca-certificates curl
gstreamer gst-libav gst-plugin-va gst-plugins-bad gst-plugins-base gst-plugins-good gst-plugins-ugly
libglvnd libva libva-intel-driver libva-utils mesa openbox pulseaudio pulseaudio-alsa
python python-websockets supervisor tar xdotool xorg-server-xvfb xz
```

Runtime multilib packages when `WINE_ENABLE_MULTILIB=1`:

```text
lib32-alsa-lib lib32-alsa-plugins lib32-fontconfig lib32-freetype2
lib32-libglvnd lib32-libpulse lib32-libx11 lib32-libxcursor lib32-libxext
lib32-libxi lib32-libxinerama lib32-libxrandr lib32-libxrender lib32-mesa
```

The image removes `/usr/lib/dri/iHD_drv_video.so` so the Intel VA path uses the stable `i965` driver on the DS225+.

Compiled helper:

```bash
gcc container/stream-helper.c -o /opt/ra2/stream-helper \
  $(pkg-config --cflags --libs gstreamer-1.0 gstreamer-app-1.0)
```

Container user, workdir, and entrypoint:

```text
User: commander
UID: 1000
Workdir: /home/commander
Entrypoint: /opt/ra2/entrypoint.sh
Exposed container port: 6080
```

Image environment defaults:

```text
PATH=/opt/wine/bin:${PATH}
DISPLAY=:1
WINEARCH=win32
WINEPREFIX=/home/commander/.wine
WINEDEBUG=-all
LIBVA_DRIVER_NAME=i965
GST_VAAPI_ALL_DRIVERS=1
GST_VA_ALL_DRIVERS=1
LIBGL_ALWAYS_SOFTWARE=1
MESA_GL_VERSION_OVERRIDE=2.1
ULTRA_STREAM_ENABLED=1
ULTRA_GATEWAY_PORT=6080
ULTRA_VIDEO_CODEC=H264
ULTRA_VIDEO_FPS=24
RESOLUTION=1024x768
RA2_DISPLAY_DEPTH=16
RA2_ENABLE_NOVNC_FALLBACK=0
```

Golden-master ultra compose defaults:

```text
ULTRA_GATEWAY_TLS=1
ULTRA_VIDEO_REQUIRE_HW=1
RESOLUTION=1024x768            # Xvfb display size; native stream size follows it
RA2_DISPLAY_DEPTH=16           # Xvfb bit depth; 16 is the validated value for RA2
ULTRA_VIDEO_WIDTH=             # optional deploy-time encode-size override (unset = display)
ULTRA_VIDEO_HEIGHT=
ULTRA_VIDEO_FPS=24
ULTRA_VIDEO_BITRATE=900000
ULTRA_VIDEO_KEYFRAME_SECONDS=1
ULTRA_VIDEO_DIAGNOSTICS=1
ULTRA_H265_TEST_ENABLED=1      # exposes hardware H.265 8-bit/10-bit options; H.264 stays default
ULTRA_AUDIO_CODEC=opus
ULTRA_AUDIO_BITRATE=64000
ULTRA_AUDIO_FRAME_MS=10
ULTRA_AUDIO_RATE=44100
ULTRA_AUDIO_TRANSPORT_RATE=48000
ULTRA_STREAM_CPUSET=2,3
ULTRA_VIDEO_GPU_SCALE=1
RA2_ENABLE_AUDIO_PROXY=0
RA2_ENABLE_LATENCY_PROXY=0
WEBRTC_ENABLED=0
```

Video codec and resolution options (per session, browser transport menu):

```text
Codecs: H.264 (default) | H.265 8-bit | H.265 10-bit (Main10/P010)
        All three are VA-API hardware encodes; HEVC Main and Main10
        EncSlice entrypoints are verified on the J4125 i965 driver.
Stream resolution: native (display) | 960x720 | 800x600 | 640x480
        Downscaling happens on the GPU (vapostproc); the gateway maps
        input coordinates back onto the game display.
```

CPU partitioning is part of the build contract, not a tuning detail:

```text
PLAYER1_GAME_CPUSET=0     # game 1 owns core 0
PLAYER2_GAME_CPUSET=1     # game 2 owns core 1
ULTRA_STREAM_CPUSET=2,3   # both capture/encode helpers share cores 2-3
```

Each game is pinned to exactly one core; the capture/encode helper is pinned to the remaining cores so encoding can never preempt a game core. The game-side pin is the core stability invariant and must not be removed.

Runtime device and group requirements:

```text
Device: /dev/dri mounted at /dev/dri
RENDER_GID=937
VIDEO_GID=44
```

Golden-master bind mounts:

```text
./container/entrypoint-ultra.sh -> /opt/ra2/entrypoint.sh:ro
./container/supervisord.ultra.conf -> /opt/ra2/supervisord.conf:ro
./container/start-game-ultra.sh -> /opt/ra2/start-game-ultra.sh:ro
./container/start-stream-gateway.sh -> /opt/ra2/start-stream-gateway.sh:ro
./container/log-video-diagnostics.sh -> /opt/ra2/log-video-diagnostics.sh:ro
./container/winedbg-minidump.sh -> /opt/ra2/winedbg-minidump.sh:ro
./container/ra2-stream-gateway.py -> /opt/ra2/ra2-stream-gateway.py:ro
./container/stream-helper.c -> /opt/ra2/stream-helper.c:ro
./container/remote-ultra -> /opt/ra2/remote-ultra:ro
${LOGS_DIR:-/volume2/Data/App_Development/ra2-lan-party/logs} -> /home/commander/ra2-logs-root:rw
```

The main compose file supplies the per-player assets, Wine prefixes, TLS material, ports, and LAN addresses. For the current DS225+ layout, the persistent paths are:

```text
Assets: /volume2/Data/App_Development/ra2-lan-party/assets
Player 1 prefix: /volume2/Data/App_Development/ra2-lan-party/prefixes/player1-win32
Player 2 prefix: /volume2/Data/App_Development/ra2-lan-party/prefixes/player2-win32
Logs: /volume2/Data/App_Development/ra2-lan-party/logs
TLS: /volume2/Data/App_Development/ra2-lan-party/tls
```

## Optimization And Efficiency (Intel J4125)

The golden-master container is tuned for the Synology DS225+ host it runs on. All figures below were measured live on that hardware.

### Measured hardware baseline

```text
CPU: Intel Celeron J4125, 4 cores @ 2.0 GHz (Gemini Lake)
RAM: ~1.7 GB total (6 GB upgrade recommended; stock runs under memory pressure)
iGPU: Intel UHD 600, VA-API via i965 driver
GPU encoders present: vah264enc, vah264lpenc, vah265enc
GPU post-processing present: vapostproc
Ultra image size: ~3.41 GB
Per-container memory: ~240-260 MB of a 512 MB limit (~50%)
```

### What the container optimizes and the effect

| Optimization | Mechanism | Measured / structural effect |
|--------------|-----------|------------------------------|
| Game CPU isolation | `gamemd.exe` pinned to one core per player (`taskset`, watchdog re-pin) | Verified: game 1 on core 0, game 2 on core 1; eliminated the crash/lockup pattern |
| Encoder CPU isolation | Capture/encode helper pinned to `ULTRA_STREAM_CPUSET=2,3` | Verified: helper affinity list `2,3`; encode never lands on a game core |
| Hardware video encode | VA-API `vah264enc` / `vah265enc` on the iGPU (`ULTRA_VIDEO_REQUIRE_HW=1`); HEVC Main and Main10 (10-bit P010) entrypoints verified | Encode runs on the GPU instead of burning CPU with `x264`; H.265 8/10-bit measured at the same pipeline cost as H.264 (~14% of a core) |
| GPU convert/scale | `vapostproc` converts/scales/uploads on the iGPU, zero-copy VA surfaces into the encoder (`ULTRA_VIDEO_GPU_SCALE=1`); also powers per-session stream downscales (960x720/800x600/640x480) | Measured: helper pipeline CPU cut ~40% (20.5% -> 12.3% of a core) |
| Gateway hot path | Per-frame `json.loads` replaced with a prefix check in the WSS relay | Removes a JSON parse of every base64 video/audio payload at 24 fps |
| Low-bandwidth audio | Opus low-latency, 64 kbps, 10 ms frames | Low CPU and low bitrate vs PCM; single selected-stream audio path only |
| Latency-first buffering | GStreamer `queue ... max-size-buffers=1 leaky=downstream`, `appsink drop=true sync=false` | Drops stale frames before conversion work is spent on them |
| Lean capture surface | Xvfb at 16-bit depth, 1024x768 @ 24 fps, 900 kbps | Smaller capture/convert/encode workload sized to RA2 motion |
| Single port, single session | One HTTPS/WSS port per player; newer browser session replaces the old one | No duplicate encoders or duplicate audio per player |
| Stable VA driver | Build removes `iHD_drv_video.so` so VA-API uses `i965` | Avoids the unstable iHD path on Gemini Lake |

### Measured pipeline benchmarks (20 s runs against the live game display, cores 2-3)

```text
capture only (ximagesrc floor):                  1.8% of one core
CPU convert -> vah264enc (previous pipeline):   20.5% of one core
GPU convert via vapostproc -> vah264enc (now):  12.3% of one core   (-40%)
GPU convert -> vah264lpenc (optional):          10.6% of one core   (-48%)
GPU convert -> vah265enc 8-bit (NV12):          13.8% of one core
GPU convert -> vah265enc 10-bit (P010/main-10): 14.2% of one core
```

The capture path is RGB16 (16-bit Xvfb), which VA-API cannot ingest directly; the adopted pipeline does a cheap CPU RGB16->BGRx expand, then `vapostproc` performs the expensive color conversion, scaling, and surface upload on the iGPU.

### Live resource profile (measured in production)

```text
gamemd.exe (player 1): ~75-100% of one core, pinned to core 0
gamemd.exe (player 2): ~75-100% of one core, pinned to core 1
stream-helper (per active stream): ~16% of a core total (was ~23% before GPU convert), cores 2-3
ra2-stream-gateway (WSS relay): ~9% of a core while streaming (was ~13% before hot-path fix)
Stream delivery: ~22 effective fps at the 24 fps target, 437 frames over a 20 s probe
Xvfb + PulseAudio: light, on cores 2-3
```

The helper total includes base64 encoding and stdout I/O on top of the GStreamer pipeline, which is why the production figure (~16%) sits above the pipeline-only benchmark (12.3%).

With both games running and the two games owning cores 0 and 1, the two encode helpers and all support processes share cores 2 and 3. This keeps each game's core clean while encoding, which is the main driver of stable two-player play on a 4-core CPU.

### Evaluated next-step optimizations (not on the default golden path)

These are available on the hardware and are the logical next efficiency steps, intentionally left off the default until they have long gameplay validation:

- `vah264lpenc` low-power encoder: measured a further ~14% relative helper CPU cut over the adopted GPU pipeline, but it swaps the proven encoder element, so it stays optional.
- Binary WebSocket frames: the WSS protocol base64-encodes media (~33% bandwidth overhead); a binary framing change would cut relay CPU and bandwidth but touches the whole client/server protocol.
- Host RAM upgrade to 6 GB: the largest remaining lever; the stock 1.7 GB box runs with swap engaged.

Rollback levers: `ULTRA_VIDEO_GPU_SCALE=0` reverts to the CPU convert pipeline without a rebuild, and the previous image stays tagged `ra2-lan-party:ultra-prev` during upgrades.

## Legal And Asset Boundary

No copyrighted game files, serials, or third-party compatibility DLLs are included. You must supply your own legally owned Red Alert 2 / Yuri's Revenge files, plus the compatibility wrappers you choose to use.

Expected NAS asset path:

```text
/volume2/Data/App_Development/ra2-lan-party/assets
```

## Quick Start

On the Synology:

```bash
mkdir -p /volume2/Data/App_Development/ra2-lan-party/project
cd /volume2/Data/App_Development/ra2-lan-party/project
```

Copy this project into:

```text
/volume2/Data/App_Development/ra2-lan-party/project
```

Prepare directories:

```bash
cd /volume2/Data/App_Development/ra2-lan-party/project
sh scripts/prepare-nas.sh
```

Copy your game files and compatibility DLLs into:

```text
/volume2/Data/App_Development/ra2-lan-party/assets
```

Configure:

```bash
cp .env.example .env
vi .env
```

Run:

```bash
sh scripts/bootstrap-nas.sh launch
```

Optional hardware video-transcoding tooling is available through `compose.transcode.yaml`. It grants `/dev/dri` access for FFmpeg/GStreamer VA-API tests while leaving the default noVNC path unchanged:

```bash
RA2_COMPOSE_TRANSCODE=1 docker compose --env-file .env -f compose.yaml -f compose.transcode.yaml up -d --build
```

Connect:

**Primary (after Moonlight validation):**

```text
Moonlight client → NAS LAN IP or Tailscale IP
See docs/MOONLIGHT_EXPERIMENT.md
```

**Admin / recovery (noVNC):**

```text
Player 1: https://192.168.0.193:6081/vnc.html
Player 2: https://192.168.0.193:6082/vnc.html
```

**Legacy browser fallback (WebRTC):**

```text
Player 1: https://192.168.0.193:6081/remote.html?signal=6083&input=6085
```

Preflight before play:

```bash
sh scripts/check-host-prerequisites.sh   # VA-API, uinput, RAM
sh scripts/check-moonlight-ready.sh        # Moonlight experiments
sh scripts/check-webrtc-ice-reachability.sh  # WebRTC fallback only
```

The noVNC page includes a small **Latency** panel. It measures browser-to-container
round-trip time through the same HTTPS/WSS endpoint and links to quick noVNC presets:

- `lowest latency`: lower compression work for faster response on a LAN
- `balanced`: moderate compression/quality for noisier links

Tune these in `.env`, recreate the players, then compare the panel:

```bash
RESOLUTION=1024x768
AUDIO_BUFFER_MIN_REMAIN=2
AUDIO_DRIFT_MAX_TOLERANCE=0.25
AUDIO_WEBM_CLUSTER_MS=50
AUDIO_OPUS_FRAME_MS=10
AUDIO_QUEUE_BUFFERS=2
```

See `docs/HTTPS.md` for TLS options (self-signed or DSM reverse proxy), `compose.https.yaml` for HTTPS overlay, and `docs/DEPLOY_SYNOLOGY.md` for the full deployment guide.

Verify a live deployment on the NAS:

```bash
sudo sh scripts/verify-deployment.sh
```

Hardware transcode verification is optional on the DS225+ because Synology's i915 stack currently exposes `VAProfileNone` even when `/dev/dri` is mounted correctly.

## NAS automation

Verify locally:

```bash
sh scripts/verify-ready.sh
```

On the NAS:

```bash
sh scripts/bootstrap-nas.sh prepare   # validate layout without game files
sh scripts/bootstrap-nas.sh build       # pre-build runtime image (sudo if needed)
sh scripts/ingest-assets.sh /path/to/your/ra2-folder
sh scripts/validate-env.sh
sh scripts/bootstrap-nas.sh launch      # start both players
sh scripts/bootstrap-nas.sh status
```

From your Mac after local edits:

```bash
sh scripts/sync-to-nas.sh
```

See `docs/ASSETS_CHECKLIST.md` and `docs/READY.md`.

## Tests

```bash
sh scripts/run-tests.sh      # unit + contract tests (38+)
sh scripts/verify-ready.sh   # tests + shell syntax + compose render
```

Checkpoint layers covered by `tests/`:

| Checkpoint | What it guards |
|------------|----------------|
| Environment | `.env` layout, unique serials, browser ports |
| TLS / HTTPS | cert generation, uid 1000 ownership, compose overlay selection |
| Compose | static LAN IPs, secrets required, HTTPS/transcode overlays |
| Container runtime | Wine entrypoint, supervisord pipeline, audio + websockify |
| NAS automation | bootstrap, preflight, ingest, verify-deployment contracts |
| Browser endpoint | HTTP vs HTTPS healthcheck, audio proxy handshake |

On the NAS after deploy:

```bash
sudo sh scripts/verify-deployment.sh
```

## Important Files

- `compose.yaml`: Synology two-player stack.
- `compose.sunshine.yaml` / `compose.wolf.yaml`: Moonlight proof-of-concept experiments.
- `compose.tailscale.yaml`: Secure remote access for Moonlight.
- `compose.webrtc.yaml`: Legacy browser WebRTC overlay (fallback only).
- `.env.example`: deployment values to copy into `.env`.
- `docs/MOONLIGHT_EXPERIMENT.md`: Moonlight primary path guide.
- `docs/TAILSCALE.md`: Remote access without exposing GameStream ports.
- `container/Dockerfile`: minimal Arch Linux Wine/noVNC image.
- `container/entrypoint.sh`: first-run Wine prefix initialization and registry setup.
- `container/supervisord.conf`: process supervision for display, browser bridge, and game.
- `config/`: game configuration templates for the assets folder.
- `scripts/prepare-nas.sh`: NAS directory preparation script.
