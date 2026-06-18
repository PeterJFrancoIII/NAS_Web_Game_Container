# RA2 NAS Golden Master — Final Lock (June 2026)

**Tag:** `golden-master-2026-06-udp-lan` (supersedes `golden-master-2026-06` for video transport)  
**Repo:** `synology-ra2-arch/` (GitHub: `NAS_Web_Game_Container`)  
**NAS path:** `/volume2/Data/App_Development/ra2-lan-party/project`

This is the **single authoritative document** for reproducing, operating, and restoring the production ultra browser streaming stack. Supports **Red Alert 2 / Yuri's Revenge**, **Age of Empires II (1999)**, and **StarCraft + Brood War** from one container image per player.

**LAN + remote UDP video (verified June 2026):** split-protocol WebRTC video + WSS audio/control. LAN at `https://192.168.0.193:6081/`; remote at `https://peterjfrancoiii2.synology.me:6081/` over TURN relay with server-side LAN coturn (NAT hairpin bypass). See [`GOLDEN_MASTER_UDP_LAN.md`](GOLDEN_MASTER_UDP_LAN.md) for the locked UDP descriptor, ports, and verification checklist.

Written for **low-context LLM agents** and developers with limited prior exposure to the project.

**Production URLs:**

| Player | LAN | Remote (DDNS) |
|--------|-----|---------------|
| 1 | `https://192.168.0.193:6081/` | `https://peterjfrancoiii2.synology.me:6081/` |
| 2 | `https://192.168.0.193:6082/` | `https://peterjfrancoiii2.synology.me:6082/` |

---

## 1. Hardware and host

### 1.1 Reference deployment (verified)

| Component | Spec |
|-----------|------|
| **Device** | Synology DS225+ NAS |
| **CPU** | Intel Celeron J4125 — 4 cores @ 2.0 GHz (Gemini Lake) |
| **iGPU** | Intel UHD 600 — VA-API via **`i965`** driver (not iHD) |
| **RAM** | Stock ~1.7 GB (tight); **18 GB upgrade** on production NAS |
| **Storage** | `/volume2/Data/App_Development/ra2-lan-party/` |
| **LAN IP** | `192.168.0.193` |
| **DDNS** | `peterjfrancoiii2.synology.me` |
| **SSH** | Port `23921` — use DDNS host `MediaServer2` if LAN SSH times out |

### 1.2 Required host capabilities

- Docker / Container Manager with `/dev/dri` passthrough
- `RENDER_GID=937`, `VIDEO_GID=44` for VA-API render node
- Router forwards **TCP 6081 + 6082** to NAS for remote play
- **LAN UDP (verified):** forward **UDP+TCP 62001–62020** and **TCP 5349** (TURNS) for remote WebRTC; LAN play works at `https://192.168.0.193:6081/` without hairpin
- Client: **Chromium, Chrome, or Edge** (WebCodecs + WebRTC + WSS required; HTTPS mandatory)

### 1.3 CPU layout (do not change)

| Core | Assignment |
|------|------------|
| 0 | Game process player 1 (`PLAYER_ID=1`) |
| 1 | Game process player 2 (`PLAYER_ID=2`) |
| 2–3 | `stream-helper` + gateway + Xvfb + Pulse (`ULTRA_STREAM_CPUSET=2,3`) |

Watchdog in `run-game-session.sh` re-applies `taskset` — Wine children escape the initial pin.

---

## 2. Current container state and attributes

### 2.1 What runs in production

| Item | Value |
|------|-------|
| **Image** | `ra2-lan-party:ultra` (`container/Dockerfile.ultra`) |
| **Compose** | `compose.yaml` + `compose.https.yaml` + `compose.ultra.yaml` + `compose.ultra-udp.yaml` + `compose.ultra-udp-host.yaml` |
| **Flags** | `RA2_COMPOSE_ULTRA=1`, `RA2_COMPOSE_ULTRA_UDP=1`, `RA2_COMPOSE_ULTRA_UDP_HOST=1` |
| **Containers** | `Cloud_Gaming_Player1`, `Cloud_Gaming_Player2`, `RA2_Coturn` |
| **Base OS** | Arch Linux (inside container) |
| **Wine** | Kron4ek 10.8, `amd64` package, **`win32` prefix**, multilib |
| **Game launcher** | `GAME_LAUNCHER_ENABLED=1` (default) |
| **Game manifest** | `config/games.json` |
| **Browser client** | `container/remote-ultra/` — **`SETTINGS_VERSION=66`**, `webrtc-ice-utils.js?v=102`, `ultra-play.js?v=102` |

### 2.2 Supported games (`config/games.json`)

| ID | Title | Executable | Supervised process | Assets mount |
|----|-------|------------|-------------------|--------------|
| `ra2` | Red Alert 2 + Yuri's Revenge | `RA2MD.exe` | `gamemd.exe` | `ASSETS_DIR` → `game_assets` |
| `aoe2` | Age of Empires II (1999) | `EMPIRES2.EXE` | `EMPIRES2.EXE` | `AOE2_ASSETS_HOST` → `aoe2_assets` |
| `starcraft` | StarCraft + Brood War | `StarCraft.exe` | `StarCraft.exe` | `SC_ASSETS_HOST` → `sc_assets` |

RA2 uses transport INI sync (`sync-game-transport.sh`); AoE2 and StarCraft use per-game `ddraw.ini` overlays and writable work dirs.

### 2.3 Per-container processes

| Process | Role |
|---------|------|
| PulseAudio | `game` null sink @ 48 kHz; TCP capture port 4711 |
| Xvfb | Headless display; RandR tiers 480p/720p/1080p |
| Openbox | Minimal WM |
| `start-game-ultra.sh` | Launcher supervisor loop |
| `run-game-session.sh` | Launches selected game via Wine |
| `ra2-stream-gateway.py` | HTTPS + WSS on container port 6080; `/webrtc-signal` proxy |
| `stream-helper` | GStreamer VA-API H.264/HEVC + Opus (WSS fallback path) |
| `webrtc-media.py` + helper | WebRTC H.264 UDP video (primary on LAN) |
| `RA2_Coturn` | TURN relay (host network, TLS 5349) |

**Not in hot path:** noVNC, x11vnc, websockify, Moonlight, Selkies.

### 2.4 Matched two-player deployment

Both players share **identical** config via `x-ra2-player-env` and `x-ra2-ultra-env`. **Only these differ:**

| | Player 1 | Player 2 |
|---|----------|----------|
| `PLAYER_SERIAL` | `PLAYER1_SERIAL` | `PLAYER2_SERIAL` |
| Wine prefix | `prefixes/player1-win32` | `prefixes/player2-win32` |
| Host port | 6081 | 6082 |
| Bridge IP | 172.22.20.11 | 172.22.20.12 |
| CPU core | 0 | 1 |

Shared: `VNC_PASSWORD`, `RA2_MEM_LIMIT`, all `ULTRA_*` vars, image, game asset mounts.

### 2.5 Browser connect flow (locked UX)

1. Page loads with overlay **Click to choose a game** — **no auto-connect**.
2. User click → WebSocket opens → server sends `hello` with available games.
3. Overlay step 2: game picker (RA2, AoE II, StarCraft).
4. User selects game → client sends `selectGame` → stream starts on `ready`.
5. **Transport → Switch game…** sends a new `selectGame` while connected.
6. If controller slot is taken, client shows **Watch stream** panel — user must **click manually** (no auto-join to spectator mode).

Client cache bust: `index.html` loads `webrtc-ice-utils.js?v=102` then `ultra-play.js?v=102`. Gateway serves static files using `urlparse(path).path` so query strings do not break JS delivery.

**UDP video (LAN + remote verified):** after ICE connects, transport must reach **`udp video: WebRTC verified/`** with rising **`webrtc rtp:`** packet counts before treating UDP as confirmed. Remote play uses **`iceTransportPolicy: "relay"`** and server-side TURN via LAN coturn. WSS `video` messages should stop incrementing after verification.

### 2.6 Transport defaults (locked)

**Server (`.env` / compose):**

| Setting | Value |
|---------|-------|
| `RESOLUTION` | `960x720` (stream; per-game native sizes in manifest) |
| `RA2_DISPLAY_DEPTH` | `24` |
| `ULTRA_VIDEO_CODEC` | `H265_10` |
| `ULTRA_VIDEO_FPS` | `24` |
| `ULTRA_VIDEO_BITRATE` | `2000000` (2.0 Mbps) |
| `ULTRA_VIDEO_REQUIRE_HW` | `1` |
| `ULTRA_VIDEO_GPU_SCALE` | `1` |
| `ULTRA_STREAM_CPUSET` | `2,3` |
| `ULTRA_H265_TEST_ENABLED` | `1` |
| `ULTRA_STREAM_CODEC_LOCK` | **empty** |
| `ULTRA_AUDIO_CODEC` | `opus` |
| `ULTRA_AUDIO_BITRATE` | `64000` |
| `ULTRA_AUDIO_RATE` | `48000` |
| `ULTRA_INPUT_MOVE_HZ` | `60` |
| `GAME_LAUNCHER_ENABLED` | `1` |
| `LIBVA_DRIVER_NAME` | `i965` |

**Browser client (`ultra-play.js`):**

| Setting | Value |
|---------|-------|
| Video quality | balanced / 24 fps |
| Codec | H.265 10-bit |
| Bitrate | 2.0 Mbps |
| Audio | Opus 64 kbps @ 48 kHz |
| Mouse poll | 60 Hz |
| Settings apply | Live `reconfigure` (no disconnect) |
| Audio unlock | On connect / first audio packet |
| Game mode | Fullscreen + pointer lock on `#gameSurface` |
| Lag cursors | White = local aim; amber = last sent to game |

---

## 3. Transport, ports, protocols, dependencies

### 3.1 Production port map

| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| **6081** | TCP HTTPS/WSS | Browser → NAS → P1 | Player 1 play page + `/stream` + `/webrtc-signal` |
| **6082** | TCP HTTPS/WSS | Browser → NAS → P2 | Player 2 play page + `/stream` |
| **62001–62010** | UDP + TCP | Browser ↔ NAS | Player 1 WebRTC media/ICE |
| **62011** | UDP + TCP | Browser ↔ NAS | Coturn TURN |
| **62015–62020** | UDP | Browser ↔ NAS | Coturn relay allocation |
| **5349** | TCP TLS | Browser ↔ NAS | TURNS (restrictive networks) |
| 6080 | TCP (internal) | Host maps to 6081/6082 | Gateway inside container |
| 6090 | TCP WSS (internal) | Gateway → webrtc-media | WebRTC signaling bridge |
| 4711 | TCP (internal) | helper → Pulse | Audio capture |
| 23921 | TCP SSH | Admin | Deploy / backup |

**Multiplayer game traffic:** UDP between player bridge IPs on Docker network — **not** forwarded to internet.

**Archived (do not forward unless experimenting):** noVNC 5900, Moonlight ports — see `docs/ARCHIVED_EXPERIMENTS.md`.

### 3.2 Wire protocol (browser ↔ gateway)

Single WSS connection per player: `wss://<host>:6081/stream` (or 6082).

**Browser → server (JSON):**

| Message | Purpose |
|---------|---------|
| `start` | Connect with transport settings |
| `reconfigure` | Live settings change |
| `selectGame` | Pick or switch game (`game`: `ra2` \| `aoe2` \| `starcraft`) |
| `watch` | Join as spectator (manual — user clicks Watch stream) |
| `ping` | RTT measurement |
| `videoPath` | Switch video transport (`wss` fallback \| `webrtc` UDP) |
| `mousemove`, `mousedown`, `mouseup`, `wheel` | Pointer input |
| `keydown`, `keyup`, `keyup_all` | Keyboard |

**Server → browser (JSON):**

| Message | Purpose |
|---------|---------|
| `hello` | Session + available games + controller presence |
| `ready` | Stream active (`reason`: `start`, `watch`, `display_change`, `helper_restart`, …) |
| `selectGameResult` | Game launch success/failure |
| `controllerBusy` | Another client holds the controller slot |
| `waitingForController` | Spectator waiting for controller |
| `role` | `controller` or `spectator` |
| `video` | Base64 H.264/HEVC bitstream |
| `audio` | Base64 Opus or PCM |
| `pong` | RTT reply |

Video/audio use base64 in JSON (~33% overhead — known improvement area).

### 3.3 NAS directory layout

```text
/volume2/Data/App_Development/ra2-lan-party/
  assets-game2/       ← ASSETS_DIR for RA2 (NOT in backup — copyrighted)
  prefixes/           ← Wine state + serials (IN backup)
  project/            ← This repo (IN backup)
  logs/player1,2/     ← Diagnostics (IN backup)
  tls/                ← HTTPS certs (IN backup)
  backups/            ← backup-golden-master.sh output
  .env                ← Secrets (IN backup — protect archive)

/volume2/Data/Games/  ← AoE2 + StarCraft unpacked trees (NOT in backup)
```

### 3.4 Key files and scripts

| Path | Role |
|------|------|
| `compose.yaml` | Two-player base, shared env anchor |
| `compose.https.yaml` | TLS mounts |
| `compose.ultra.yaml` | Ultra overlay, VA-API devices, multi-game mounts |
| `config/games.json` | Game profiles (exe, assets, display, ddraw) |
| `container/Dockerfile.ultra` | Image build |
| `container/ra2-stream-gateway.py` | HTTPS/WSS server, input via xdotool, game select |
| `container/stream-helper.c` | GStreamer capture/encode |
| `container/start-game-ultra.sh` | Launcher supervisor loop |
| `container/run-game-session.sh` | Single-game session runner |
| `container/game-launcher.sh` | CLI game menu (container-side) |
| `container/secure-game-select.sh` | Validates browser game selection |
| `container/remote-ultra/ultra-play.js` | Browser client |
| `scripts/redeploy-ultra.sh` | WebRTC tests + sync + recreate players + coturn |
| `scripts/run-webrtc-tests.sh` | ICE unit tests (Python + Node) |
| `scripts/probe-webrtc-turn.sh` | TURN credential probe on NAS |
| `tests/test_webrtc_ice.py` | Server ICE expansion/sanitize tests |
| `tests/ultra_play_ice_utils.test.mjs` | Browser ICE helper tests |
| `scripts/restart-audio-ultra.sh` | Pulse → game → gateway |
| `scripts/unpack-starcraft-broodwar.sh` | Stage SC disc assets on NAS |
| `scripts/validate-env.sh` | Pre-flight `.env` |
| `scripts/backup-golden-master.sh` | Image + runtime backup (no game files) |
| `scripts/sync-to-nas.sh` | Mac → NAS rsync/tar |
| `tests/test_project_contracts.py` | 79 contract tests |

### 3.5 Container packages (Arch)

**Runtime highlights:** Wine 10.8 (Kron4ek), GStreamer + gst-plugin-va, PulseAudio, Xvfb, Openbox, Python 3 + websockets, xdotool, supervisor.

**Build removes:** `/usr/lib/dri/iHD_drv_video.so` — forces stable `i965` on Gemini Lake.

**Compiled:** `stream-helper` from `stream-helper.c` via gcc + GStreamer pkg-config.

### 3.6 Required `.env` keys

```bash
PLAYER1_SERIAL=<unique>
PLAYER2_SERIAL=<different>
VNC_PASSWORD=<shared>
ASSETS_DIR=.../assets-game2
NAS_PUBLIC_HOSTNAME=peterjfrancoiii2.synology.me
PREFIX1_DIR=.../prefixes/player1-win32
PREFIX2_DIR=.../prefixes/player2-win32
LOGS_DIR=.../logs
TLS_DIR=.../tls
RENDER_GID=937
VIDEO_GID=44
# Optional multi-game asset overrides:
# AOE2_ASSETS_HOST=...
# SC_ASSETS_HOST=...
# SC_DISC_HOST=...
```

---

## 4. Replication checklist (agent / developer)

```bash
# 1. Clone repo, copy to NAS project/
# 2. Prepare dirs
cd /volume2/Data/App_Development/ra2-lan-party/project
sh scripts/prepare-nas.sh
cp .env.example .env   # edit serials, VNC_PASSWORD, ASSETS_DIR
sh scripts/validate-env.sh
sh scripts/generate-tls-certs.sh   # if tls/ empty

# 3. Stage game files separately (legal — not in repo)
sh scripts/ingest-assets.sh /path/to/RA2
# AoE2 + StarCraft: unpack to paths in compose.ultra.yaml
sh scripts/unpack-starcraft-broodwar.sh   # if using StarCraft

# 4. Build + deploy both players (UDP golden master)
RA2_COMPOSE_ULTRA=1 RA2_COMPOSE_ULTRA_UDP=1 RA2_COMPOSE_ULTRA_UDP_HOST=1 sh scripts/redeploy-ultra.sh

# 5. Verify
sh scripts/run-webrtc-tests.sh
python3 -m pytest tests/ -q
curl -sk -o /dev/null -w "%{http_code}\n" https://127.0.0.1:6081/
curl -sk -o /dev/null -w "%{http_code}\n" "https://127.0.0.1:6081/ultra-play.js?v=102"
curl -sk https://127.0.0.1:6081/turn-ice.json | python3 -m json.tool | head
```

**From Mac after edits:**

```bash
NAS_HOST=MediaServer2 RA2_ULTRA_BUILD=0 sh scripts/redeploy-ultra.sh
```

**Manual play test:** click to connect, pick each game, audio, game mode (fullscreen + lock), dual cursors, switch game via Transport, spectator manual join, 10+ min stable gameplay.

---

## 5. Known bugs and fixes

| # | Issue | Fix |
|---|-------|-----|
| 1 | Map load freeze (RA2) | Never rewrite game INI in `start_helper()` — only at game launch via `sync-game-transport.sh` |
| 2 | HEVC missing from menu | Leave `ULTRA_STREAM_CODEC_LOCK` empty |
| 3 | Stale code after sync | Always `--force-recreate` containers |
| 4 | SSH LAN timeout | Use `NAS_HOST=MediaServer2` (DDNS) |
| 5 | Player 2 URL dead | Deploy both players; forward TCP 6082 |
| 6 | `VNC_PASSWORD` missing | Add shared `VNC_PASSWORD` to `.env` |
| 7 | Silent audio after Pulse restart | `restart-audio-ultra.sh` |
| 8 | Game crash / lockup | CPU pin game cores 0/1, encode 2/3 |
| 9 | VA-API black video | Remove iHD; use `LIBVA_DRIVER_NAME=i965` |
| 10 | VAProfileNone on DSM | `enable-host-transcode.sh` |
| 11 | Low RAM OOM | `two-player-low` profile; upgrade RAM |
| 12 | HEVC decode fail in browser | Auto-fallback H265_10 → H265 → H264 |
| 13 | Old client cached | Hard refresh; bump `SETTINGS_VERSION` and `?v=` in `index.html` |
| 14 | WebCodecs blocked on HTTP | Use HTTPS overlay |
| 15 | Multiplayer LAN fail (RA2) | `wsock32.dll` + bridge network |
| 16 | Game mode flicker / disconnect | Don't exit game mode on `blur`; use `gameModeBusy` grace |
| 17 | Game mode instant kick-out | Request FS + pointer lock same user gesture; no await between |
| 18 | Mouse dead in game mode | Document-level capture listeners (lock targets `#gameSurface`) |
| 19 | Stuck **L** key on Ctrl+Alt+L | Shortcut handled in capture phase; never forwarded; `releasePressedKeys()` on enter |
| 20 | redeploy websockify false positive | Verify with `curl` + `docker ps` — container may still be healthy |
| 21 | **Click to choose a game** dead | Gateway must strip `?v=` from static paths (`urlparse(path).path`); otherwise JS returns 426 |
| 22 | Spectator auto-joined too fast | Removed auto `watchStream()` — user clicks **Watch stream** manually |
| 23 | Game picker blocked on connect | Do not call `ensureDecoders()` before WebSocket opens |
| 24 | UDP claimed but still WSS video | Confirm only after `webrtc rtp:` packets rise; see `GOLDEN_MASTER_UDP_LAN.md` |
| 25 | mDNS ICE → 0 server candidates | Rewrite to LAN IP via `webrtc-ice-utils.js` before sanitize |
| 26 | Coturn TLS failed | Coturn `user: 1000:1000` + TLS mount at `/opt/ra2/tls` |
| 27 | Synology Docker UDP masquerade | `RA2_COMPOSE_ULTRA_UDP_HOST=1` for player 1 + coturn |

---

## 6. Benchmarks and improvements

### 6.1 Measured on DS225+ (J4125, production)

| Metric | Value |
|--------|-------|
| Ultra image size | ~3.41 GB |
| Per-container RAM | ~240–260 MB of 512 MB limit |
| Game process CPU | ~75–100% of one core (pinned) |
| `stream-helper` CPU | ~12–16% of one core (with GPU convert) |
| Gateway CPU while streaming | ~9% of one core |
| Effective stream fps | ~22 fps at 24 fps target |
| GPU pipeline vs CPU convert | **−40%** helper CPU with `vapostproc` |

**Pipeline benchmarks (20 s, cores 2–3):**

| Pipeline | CPU |
|----------|-----|
| Capture only | 1.8% |
| CPU convert → vah264enc (old) | 20.5% |
| GPU vapostproc → vah264enc (current) | 12.3% |
| GPU → vah265enc 10-bit | 14.2% |

### 6.2 Potential improvements (not on default path)

| Improvement | Expected gain | Risk |
|-------------|---------------|------|
| `vah264lpenc` low-power encoder | ~14% more helper CPU savings | Encoder swap — needs validation |
| Binary WSS frames (not base64 JSON) | −33% bandwidth, lower gateway CPU | Protocol + client change |
| Host RAM upgrade to 6+ GB | Eliminate swap thrashing | Hardware cost |
| `SETTINGS_VERSION` cache bust | Cleaner client upgrades | Trivial |

**Rollback levers:** `ULTRA_VIDEO_GPU_SCALE=0`; tag `ra2-lan-party:ultra-prev` before image changes.

---

## 7. Stability invariants (never bypass)

1. CPU affinity — game on 0/1, encode on 2/3, watchdog re-pin
2. Wine `amd64` + `win32` prefix + multilib
3. Pulse restart → must restart game
4. One stream-helper per active session
5. RA2 INI sync at launch only — not during helper start
6. Opus 48 kHz end-to-end
7. Full input forwarding — no broad key guards
8. Game mode: `#gameSurface` for both FS and pointer lock; document-level mouse capture when locked
9. Ctrl+Alt+L never forwarded as game keydown
10. Static assets: gateway strips URL query strings before filesystem lookup
11. Spectator join requires explicit user click — no auto `watchStream()`
12. Browser connect: show game picker before starting decoders/stream
13. UDP video: dual ICE (LAN + public), RTP-verified before switching off WSS decode path
14. `run-webrtc-tests.sh` must pass before ultra deploy sync

---

## 8. Backup and restore

### 8.1 Create backup (no game files)

```bash
# On NAS — label: golden-master-2026-06-udp-lan
cd /volume2/Data/App_Development/ra2-lan-party/project
sh scripts/backup-golden-master.sh

# From Mac
NAS_HOST=MediaServer2Local sh scripts/backup-golden-master.sh
```

Output: `/volume2/Data/App_Development/ra2-lan-party/backups/golden-master-YYYYMMDD-HHMMSS/`

- `ra2-lan-party-ultra-image.tar.gz` — Docker image
- `ra2-golden-master-runtime.tar.gz` — project, prefixes, tls, logs, .env
- **Excludes:** `assets/`, `assets-game1/`, `assets-game2/`, `RA2Yuri_Game1/`, external game trees

### 8.2 Restore sketch

```bash
docker load < ra2-lan-party-ultra-image.tar.gz
tar -xzf ra2-golden-master-runtime.tar.gz -C /volume2/Data/App_Development/ra2-lan-party
# Re-stage game files separately (RA2, AoE2, StarCraft)
RA2_COMPOSE_ULTRA=1 sh scripts/redeploy-ultra.sh
```

---

## 9. Verification

```bash
sh scripts/run-webrtc-tests.sh
python3 -m pytest tests/ -q
RA2_COMPOSE_ULTRA=1 sh scripts/check-ultra-ready.sh
curl -sk -o /dev/null -w "6081=%{http_code}\n" https://192.168.0.193:6081/
curl -sk -o /dev/null -w "js=%{http_code}\n" "https://192.168.0.193:6081/ultra-play.js?v=102"
# LAN play: transport panel shows "WebRTC verified" + rising webrtc rtp pkts
```

---

## 10. Document index

| Doc | Use |
|-----|-----|
| **This file** | Authoritative golden master |
| `GOLDEN_MASTER_UDP_LAN.md` | Locked LAN UDP WebRTC descriptor |
| `README.md` | Repo entry point |
| `assets-example/README.md` | Game asset staging per title |
| `docs/ULTRA_LIGHT_ARCH_STREAMING.md` | Transport menu shorthand |
| `docs/HTTPS.md` | TLS options |
| `docs/NAS_DEPLOY_STATUS.md` | Operator snapshot |
| `docs/ARCHIVED_EXPERIMENTS.md` | Deprecated paths |

**Lock date:** 14 June 2026 (`golden-master-2026-06-udp-lan`). Do not deploy archived compose overlays on production NAS.
