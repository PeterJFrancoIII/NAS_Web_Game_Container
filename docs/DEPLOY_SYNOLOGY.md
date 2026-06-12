# Synology DS225+ Deployment

This project targets the audited DS225+ layout:

- NAS hostname: `MediaServer2`
- DSM route: `ovs_eth0` through `192.168.0.1`
- NAS LAN IP: `192.168.0.193`
- Persistent app root: `/volume2/Data/App_Development/ra2-lan-party`

The containers use an internal Docker bridge, not macvlan. Player 1 is always `172.22.20.11`, Player 2 is always `172.22.20.12`, and browsers connect through NAS ports `6081` and `6082`.

## Streaming paths

| Path | Purpose | Documentation |
|------|---------|---------------|
| **Ultra Arch browser** | **Production** — HTTPS/WSS + WebCodecs | `docs/GOLDEN_MASTER.md`, `docs/ULTRA_LIGHT_ARCH_STREAMING.md` |
| Moonlight + Sunshine/Wolf | Archived experiment | `docs/ARCHIVED_EXPERIMENTS.md` |
| noVNC | Archived (base image; disabled in ultra) | §9 below |
| WebRTC `remote.html` | Archived legacy fallback | §9 below |
| Tailscale | Archived remote Moonlight | `docs/TAILSCALE.md` |

Production deploy:

```bash
RA2_COMPOSE_ULTRA=1 sh scripts/redeploy-ultra.sh
RA2_COMPOSE_ULTRA=1 sh scripts/check-ultra-ready.sh
```

**18 GB RAM** on the current NAS removes the old 6 GB upgrade gate. Prefer wired **2.5GbE or 1GbE** for remote play.

## 1. Copy Project To NAS

Copy this project into:

```text
/volume2/Data/App_Development/ra2-lan-party/project
```

## 2. Prepare NAS Folders

SSH to the NAS, then run the prep script from the copied project:

```bash
cd /volume2/Data/App_Development/ra2-lan-party/project
sh scripts/prepare-nas.sh
```

Run this before `docker compose up`. It creates assets/prefixes/logs with UID `1000` ownership so Wine can write its prefixes.

## 3. Add Game Assets

Copy your legally owned Red Alert 2 / Yuri's Revenge installation files into:

```text
/volume2/Data/App_Development/ra2-lan-party/assets
```

Also place these compatibility files in that same assets folder:

- `ddraw.dll` and `ddraw.ini` from cnc-ddraw.
- `wsock32.dll` from an IPX-to-UDP wrapper that supports Red Alert 2 LAN play.
- `ipxwrapper.ini` from this project's `config` folder if your wrapper uses it.
- `RA2.ini` and `RA2MD.ini` templates from this project's `config` folder, unless you already have tuned versions.

The container validates `RA2MD.exe` or your configured `GAME_EXE`, `ddraw.dll`, `ddraw.ini`, and `wsock32.dll` at startup. Compatibility DLLs and config files are refreshed into each Wine prefix on restart, so wrapper updates do not require deleting the whole prefix.

This repository intentionally does not provide game binaries, serials, or third-party DLL downloads.

LAN multiplayer depends on the wrapper, not just static IPs. Confirm both containers can see `172.22.20.11` and `172.22.20.12`, and tune `ipxwrapper.ini` for the wrapper you install.

## 4. Configure Environment

On the NAS:

```bash
cd /volume2/Data/App_Development/ra2-lan-party/project
cp .env.example .env
vi .env
sh scripts/validate-env.sh
```

Change at least:

- `PLAYER1_VNC_PASSWORD`
- `PLAYER2_VNC_PASSWORD`
- `PLAYER1_SERIAL`
- `PLAYER2_SERIAL`

Use two unique serial values from legitimately owned installations/copies. Duplicate serials can prevent LAN multiplayer.

Optional staged workflow before assets arrive:

```bash
sh scripts/bootstrap-nas.sh prepare
sh scripts/bootstrap-nas.sh build
```

## 5. Start The Stack

Running two Wine game instances on the stock 2 GB DS225+ is an OOM risk, especially alongside Plex or other containers. The research recommends expanding RAM to **6 GB** before treating Moonlight or two-player production as stable.

```bash
cd /volume2/Data/App_Development/ra2-lan-party/project
sh scripts/bootstrap-nas.sh launch
```

Verify:

```bash
docker compose ps
docker network inspect ra2-lan-party_ra2_lan
docker logs --tail=100 ra2-player-1
docker logs --tail=100 ra2-player-2
```

Expected internal addresses:

```text
ra2-player-1: 172.22.20.11
ra2-player-2: 172.22.20.12
```

## 6. Optional VA-API Transcoding Tooling

The runtime image includes FFmpeg, GStreamer, and VA-API packages for Intel hardware-encoding experiments. The normal stack still uses noVNC/RFB; H.265/WebCodecs or WebRTC streaming requires a separate transport layer and client renderer.

If you want to test hardware encoder access from the Arch containers, first confirm the NAS exposes DRM devices:

```bash
ls -lah /dev/dri
stat -c '%g %n' /dev/dri/renderD128 /dev/dri/card0
```

On the target DS225+ test system, `/dev/dri/renderD128` is owned by group `937` (`videodriver`), so `RENDER_GID=937` is the expected value. `card0` may remain `root:root` mode `600`; VA-API encoding only needs the render node.

The DS225+ uses an Intel J4125 (Gemini Lake), which supports hardware H.264 and HEVC encoding. On this CPU, the modern `iHD` driver can open successfully but only report `VAProfileNone`, which hides the usable hardware encoders. Use `LIBVA_DRIVER_NAME=i965` instead.

Set `RENDER_GID`, `VIDEO_GID`, `DRI_DEVICE`, and `LIBVA_DRIVER_NAME` in `.env` if the defaults do not match your NAS. Enable this only after the base noVNC stack is stable, then start with the overlay:

```bash
RA2_COMPOSE_TRANSCODE=1 docker compose --env-file .env -f compose.yaml -f compose.transcode.yaml up -d --build
```

Verify VA-API visibility:

```bash
sudo sh scripts/check-transcode.sh ra2-player-1
```

On Synology, Docker usually requires one `sudo` prompt for the whole script. The script does not call `sudo` again internally once it is already running as root.

If you prefer direct commands, use:

```bash
sudo /usr/local/bin/docker exec ra2-player-1 sh -lc 'LIBVA_DRIVER_NAME=i965 vainfo --display drm --device /dev/dri/renderD128'
sudo /usr/local/bin/docker exec ra2-player-1 sh -lc '/usr/bin/ffmpeg -hide_banner -encoders | grep -i vaapi'
```

Healthy output should include H.264 and HEVC VA-API encode profiles in `vainfo`, plus passing `h264_vaapi` and `hevc_vaapi` smoke tests from `scripts/check-transcode.sh`.

If `vainfo` only reports `VAProfileNone` on the DS225+, check the Synology host i915 firmware state:

```bash
sudo cat /sys/kernel/debug/dri/0/gt/uc/guc_info
sudo cat /sys/kernel/debug/dri/0/gt/uc/huc_info
```

When GuC/HuC are disabled by DSM, containers can see `/dev/dri` and FFmpeg can list VA-API encoders, but actual hardware encode will still fail until the host exposes media profiles.

The zero-copy `kmsgrab` examples in the research need a real KMS/DRM display plane. The current game desktop uses `Xvfb`, so those commands are preparation for a future streaming backend rather than a drop-in replacement for noVNC.

## 7. Measure And Tune Browser Latency

The noVNC page includes a **Latency** panel. It opens a dedicated `latency` WebSocket token through the same HTTPS/WSS endpoint as the browser session and displays:

- probe RTT between the browser and container
- min/avg/max RTT over recent samples
- active noVNC URL settings such as `compression`, `quality`, and `resize`

Use the panel to compare settings after each change. Start with response-time knobs that do not require a rebuild:

```bash
RESOLUTION=1024x768
AUDIO_BUFFER_MIN_REMAIN=3
AUDIO_DRIFT_CHECK_INTERVAL_MS=2000
AUDIO_DRIFT_MAX_TOLERANCE=0.5
AUDIO_TARGET_LATENCY=1.0
AUDIO_MAX_PLAYBACK_RATE_DELTA=0.03
AUDIO_WEBM_CLUSTER_MS=100
AUDIO_OPUS_FRAME_MS=20
AUDIO_QUEUE_BUFFERS=8
```

For the lowest LAN response time, use the panel's `lowest latency` preset or open:

```text
https://192.168.0.193:6081/vnc.html?compression=0&quality=4&resize=remote&autoconnect=1
```

If bandwidth becomes the bottleneck, try the `balanced` preset instead. The hardware encoder work is still useful for a future WebRTC/WebCodecs backend, but it does not reduce noVNC/RFB latency directly because noVNC is not using VA-API video encoding.

## 8. Enable HTTPS (Required for Stable noVNC)

noVNC 1.5+ and browser audio need a secure context. Plain `http://` URLs trigger **"noVNC requires a secure context (TLS). Expect crashes!"** and can break VNC auth and audio.

### Quick path: self-signed TLS on ports 6081/6082

```bash
cd /volume2/Data/App_Development/ra2-lan-party/project
sh scripts/generate-tls-certs.sh
docker compose --env-file .env -f compose.yaml -f compose.https.yaml up -d
```

For remote browser access through Synology DDNS, set:

```text
NAS_PUBLIC_HOSTNAME=peterjfrancoiii2.synology.me
```

Then forward external TCP `6081` to NAS `192.168.0.193:6081` and external TCP `6082` to NAS `192.168.0.193:6082`. If TLS certs already existed before adding the DDNS hostname, delete `cert.pem` and `key.pem` under `TLS_DIR` and rerun `sh scripts/generate-tls-certs.sh` so the certificate includes the public hostname.

### Alternative: DSM reverse proxy

Use a trusted DSM certificate and proxy `https://MediaServer2.local/ra2-p1` → `http://127.0.0.1:6081` (and `/ra2-p2` → `6082`). See `docs/HTTPS.md`.

## 9. Connect Players

### Ultra browser (production)

With `RA2_COMPOSE_ULTRA=1` and TLS enabled:

```text
Player 1 LAN:    https://192.168.0.193:6081/
Player 2 LAN:    https://192.168.0.193:6082/
Player 1 remote: https://peterjfrancoiii2.synology.me:6081/
Player 2 remote: https://peterjfrancoiii2.synology.me:6082/
```

Forward external TCP `6081` and `6082` to the NAS. Click **Enable audio** on first visit. Hard-refresh after client upgrades.

Audio maintenance:

```bash
sudo sh scripts/restart-audio-ultra.sh ra2-player-1
```

See `docs/GOLDEN_MASTER.md` for CPU affinity, Pulse↔Wine, and rollback rules.

### Moonlight (archived experiment)

See `docs/MOONLIGHT_EXPERIMENT.md` and `docs/ARCHIVED_EXPERIMENTS.md`.

Deploy side-by-side experiments without stopping RA2 players:

```bash
# Smallest experiment:
docker compose --env-file .env -f compose.sunshine.yaml up -d

# Preferred architecture (Wayland + inputtino):
docker compose --env-file .env -f compose.wolf.yaml up -d
```

Pair the **Moonlight** client to the NAS LAN IP. For remote play, use Tailscale — see `docs/TAILSCALE.md`. Do **not** expose GameStream ports to the internet.

Verify:

```bash
sh scripts/check-moonlight-ready.sh
sh scripts/compare-moonlight-webrtc.sh
```

### noVNC (archived — base image only; disabled when `RA2_ENABLE_NOVNC_FALLBACK=0`)

From client browsers on the LAN (use `https://` when TLS is enabled):

```text
Player 1 LAN: https://192.168.0.193:6081/vnc.html
Player 2 LAN: https://192.168.0.193:6082/vnc.html
Player 1 remote: https://peterjfrancoiii2.synology.me:6081/vnc.html
Player 2 remote: https://peterjfrancoiii2.synology.me:6082/vnc.html
```

Use the VNC passwords from `.env`. Trust the self-signed certificate on first visit, or use the DSM reverse-proxy path for a trusted cert.

If the NAS uses the secondary LAN IP, set `NAS_LAN_IP` in `.env` and regenerate TLS if needed.

### WebRTC remote play (archived legacy browser fallback)

WebRTC is **not** the production path. See `docs/ARCHIVED_EXPERIMENTS.md`. Use it only when Moonlight is unavailable or for debugging. If video is connected but the screen is blank, run:

```bash
sh scripts/check-webrtc-ice-reachability.sh
```

Enable the opt-in overlay when you need legacy browser remote play:

```bash
cd /volume2/Data/App_Development/ra2-lan-party/project
RA2_COMPOSE_WEBRTC=1 sh -c '. ./scripts/lib.sh; run_compose .env up -d --build'
```

Remote browser URLs (page served from noVNC port, signaling/input on dedicated ports):

```text
Player 1: https://peterjfrancoiii2.synology.me:6081/remote.html?signal=6083&input=6085
Player 2: https://peterjfrancoiii2.synology.me:6082/remote.html?signal=6084&input=6086
```

Router/DSM forwards for WebRTC:

- TCP `6081-6086` → NAS `6081-6086`
  - `6081`/`6082`: noVNC fallback and remote page
  - `6083`/`6084`: WebRTC signaling
  - `6085`/`6086`: keyboard/mouse input
- UDP `62001-62040` → NAS `62001-62040`
  - `62001-62020`: player 1 media
  - `62021-62040`: player 2 media

noVNC remains available as admin fallback on the same `6081`/`6082` ports.

Verify:

```bash
RA2_COMPOSE_WEBRTC=1 sudo sh scripts/verify-deployment.sh
sh scripts/check-webrtc-ice-reachability.sh
```

### Low-latency baseline (DS225+)

Default stable preset (hardware H.264, low copy cost):

```bash
WEBRTC_LATENCY_PRESET=stable
WEBRTC_VIDEO_CODEC=H264
WEBRTC_VIDEO_WIDTH=1024
WEBRTC_VIDEO_HEIGHT=768
WEBRTC_VIDEO_FPS=24
WEBRTC_VIDEO_BITRATE=1000000
WEBRTC_VIDEO_REQUIRE_HW=1
```

Redeploy from your workstation (sync + rebuild + SDP check):

```bash
NAS_HOST=MediaServer2Local sh scripts/redeploy-webrtc.sh
```

Host preflight before play sessions:

```bash
sh scripts/check-host-prerequisites.sh
sh scripts/check-low-latency-host.sh
```

### Streaming session prep (no DSM boot task)

For now, apply DRI/uinput permissions manually each boot (or after DSM updates):

```bash
sudo sh scripts/prepare-streaming-session.sh
```

When `/dev/uinput` is available, enable it in streaming containers:

```bash
RA2_COMPOSE_MOONLIGHT_UINPUT=1 sudo sh scripts/redeploy-moonlight-poc.sh wolf
```

**Deferred:** persistent boot-time setup via `scripts/dsm-boot-task.sh` in DSM Task Scheduler — add when you want permissions to survive reboot without re-running the script above.

See `docs/CONSOLIDATED_ARCHITECTURE.md` for the full implementation order.

Confirm render group IDs match `.env` (`RENDER_GID`, `VIDEO_GID`). Inside the container:

```bash
docker exec ra2-player-1 sh -lc 'id; ls -l /dev/dri/renderD128; gst-inspect-1.0 vah264enc | head'
```

### Two-player RAM profile (DS225+)

The DS225+ has about 1.7 GB RAM. Running two full player stacks can push the NAS into swap and freeze Wine (`gamemd.exe` zombie). Use the low-memory profile in `.env`:

```bash
RA2_MEMORY_PROFILE=two-player-low
RA2_MEM_LIMIT=512m
RA2_SHM_SIZE=256m
RA2_ENABLE_NOVNC_FALLBACK=1
RA2_ENABLE_AUDIO_PROXY=0
RA2_ENABLE_LATENCY_PROXY=0
AUDIO_QUEUE_BUFFERS=4
AUDIO_WEBM_CLUSTER_MS=150
```

Redeploy both players with memory checks:

```bash
NAS_HOST=MediaServer2Local sh scripts/redeploy-low-memory.sh
```

Preflight (warns on swap / low available memory):

```bash
sudo sh scripts/check-low-latency-host.sh
```

If swap remains high, lower capture load:

```bash
RESOLUTION=800x600
WEBRTC_VIDEO_WIDTH=800
WEBRTC_VIDEO_HEIGHT=600
WEBRTC_VIDEO_FPS=20
WEBRTC_VIDEO_BITRATE=800000
```

Rollback to larger per-container limits:

```bash
RA2_MEM_LIMIT=768m
RA2_SHM_SIZE=512m
RA2_ENABLE_AUDIO_PROXY=1
RA2_ENABLE_LATENCY_PROXY=1
```

### Play-session host tuning

- **Primary play:** Moonlight over LAN or Tailscale direct path.
- **Admin/recovery:** noVNC `vnc.html` on ports 6081/6082.
- Use **wired 2.5GbE or 1GbE** on client and NAS when measuring latency.
- Pause DSM **indexing**, **antivirus**, and **media thumbnail** scans during play.
- Watch swap: `free -h` — swap use correlates with latency spikes on 2–4 GB RAM models.
- Moonlight vs WebRTC comparison: `scripts/compare-moonlight-webrtc.sh`.
- Tailscale direct-path check: `scripts/check-tailscale-direct.sh`.
- Optional Selkies/Wayland comparison: see `docs/SELKIES_EXPERIMENT.md` and `scripts/compare-selkies-webrtc.sh`.
- UDP ICE test profile: `RA2_COMPOSE_WEBRTC_UDP=1 sh scripts/redeploy-webrtc-udp.sh` (TCP remains fallback).
- HEVC test: set `WEBRTC_LATENCY_PRESET=experimental` or `WEBRTC_VIDEO_CODEC=H265`, then open `remote.html?codec=H265`.
- Virtual input test: set `WEBRTC_INPUT_BACKEND=auto` (falls back to xdotool on Xvfb if uinput does not reach the game).

## 9. Synology Firewall

If DSM firewall is enabled, allow:

- Browser access from your LAN to TCP `6081` and `6082` on the NAS.
- Remote browser access from the internet to TCP `6081` and `6082` only if those router forwards are intentional.
- WebRTC remote play: TCP `6081-6086` and UDP `62001-62040` when `RA2_COMPOSE_WEBRTC=1`.
- Container subnet `172.22.20.0/24` so the two game instances can exchange UDP LAN discovery/game traffic.

Do not forward `6081` or `6082` from the internet unless you add stronger access controls outside this stack.

## 10. Troubleshooting

If noVNC opens but the game is missing, inspect assets:

```bash
ls -lah /volume2/Data/App_Development/ra2-lan-party/assets
docker logs --tail=200 ra2-player-1
```

If Wine cannot write its prefix, fix permissions:

```bash
sudo chown -R 1000:1000 /volume2/Data/App_Development/ra2-lan-party/prefixes
sudo chmod -R u+rwX,g+rwX /volume2/Data/App_Development/ra2-lan-party/prefixes
```

If the game runs but LAN discovery fails:

```bash
docker exec ra2-player-1 ip addr
docker exec ra2-player-2 ip addr
docker network inspect ra2-lan-party_ra2_lan
```

Then confirm `wsock32.dll` is present in both copied game directories:

```bash
docker exec ra2-player-1 ls -lah /home/commander/.wine/drive_c/RA2/wsock32.dll
docker exec ra2-player-2 ls -lah /home/commander/.wine/drive_c/RA2/wsock32.dll
```

If rendering is slow or both audio and video stutter, reduce render load before changing transports. The default `ddraw.ini` caps cnc-ddraw at `maxfps=20`. If the NAS is still CPU-bound, reduce `RESOLUTION` to `800x600` in `.env`, update `ddraw.ini`, `RA2.ini`, and `RA2MD.ini` to match, then recreate the containers:

```bash
docker compose down
docker compose up -d
```
