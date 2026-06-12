# RA2 NAS Golden Master — Final Lock (June 2026)

**Tag:** `golden-master-2026-06`  
**Repo:** `synology-ra2-arch/` (GitHub: `NAS_Web_Game_Container`)  
**NAS path:** `/volume2/Data/App_Development/ra2-lan-party/project`

This is the **single authoritative document** for reproducing, operating, and restoring the production Red Alert 2 / Yuri's Revenge ultra browser streaming stack. Written for **low-context LLM agents** and developers with limited prior exposure to the project.

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
- Client: **Chromium, Chrome, or Edge** (WebCodecs + WSS required)

### 1.3 CPU layout (do not change)

| Core | Assignment |
|------|------------|
| 0 | `gamemd.exe` player 1 (`PLAYER_ID=1`) |
| 1 | `gamemd.exe` player 2 (`PLAYER_ID=2`) |
| 2–3 | `stream-helper` + gateway + Xvfb + Pulse (`ULTRA_STREAM_CPUSET=2,3`) |

Watchdog in `start-game-ultra.sh` re-applies `taskset` — Wine children escape the initial pin.

---

## 2. Current container state and attributes

### 2.1 What runs in production

| Item | Value |
|------|-------|
| **Image** | `ra2-lan-party:ultra` (`container/Dockerfile.ultra`) |
| **Compose** | `compose.yaml` + `compose.https.yaml` + `compose.ultra.yaml` |
| **Flag** | `RA2_COMPOSE_ULTRA=1` |
| **Containers** | `ra2-player-1`, `ra2-player-2` |
| **Base OS** | Arch Linux (inside container) |
| **Wine** | Kron4ek 10.8, `amd64` package, **`win32` prefix**, multilib |
| **Game** | `RA2MD.exe` → `gamemd.exe` |
| **Assets mount** | `ASSETS_DIR=.../assets-game2` (read-only) |
| **Browser client** | `container/remote-ultra/` — **`SETTINGS_VERSION=32`** |

### 2.2 Per-container processes

| Process | Role |
|---------|------|
| PulseAudio | `game` null sink @ 48 kHz; TCP capture port 4711 |
| Xvfb | Headless display 960×720 @ 24-bit; RandR tiers 480p/720p/1080p |
| Openbox | Minimal WM |
| Wine + RA2 | Game on `:1` |
| `ra2-stream-gateway.py` | HTTPS + WSS on container port 6080 |
| `stream-helper` | GStreamer VA-API H.264/HEVC + Opus |

**Not in hot path:** noVNC, x11vnc, websockify, WebRTC, Moonlight, Selkies.

### 2.3 Matched two-player deployment

Both players share **identical** config via `x-ra2-player-env` and `x-ra2-ultra-env`. **Only these differ:**

| | Player 1 | Player 2 |
|---|----------|----------|
| `PLAYER_SERIAL` | `PLAYER1_SERIAL` | `PLAYER2_SERIAL` |
| Wine prefix | `prefixes/player1-win32` | `prefixes/player2-win32` |
| Host port | 6081 | 6082 |
| Bridge IP | 172.22.20.11 | 172.22.20.12 |
| CPU core | 0 | 1 |

Shared: `VNC_PASSWORD`, `RA2_MEM_LIMIT`, all `ULTRA_*` vars, `ASSETS_DIR`, image, volumes.

### 2.4 Transport defaults (locked)

**Server (`.env` / compose):**

| Setting | Value |
|---------|-------|
| `RESOLUTION` | `960x720` |
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

### 3.1 Production port map (TCP only — no UDP to internet)

| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| **6081** | TCP HTTPS/WSS | Browser → NAS → P1 | Player 1 play page + `/stream` |
| **6082** | TCP HTTPS/WSS | Browser → NAS → P2 | Player 2 play page + `/stream` |
| 6080 | TCP (internal) | Host maps to 6081/6082 | Gateway inside container |
| 4711 | TCP (internal) | helper → Pulse | Audio capture |
| 23921 | TCP SSH | Admin | Deploy / backup |

**Multiplayer game traffic:** UDP between `172.22.20.11` ↔ `172.22.20.12` on Docker bridge — **not** forwarded to internet.

**Archived (do not forward):** WebRTC UDP 62001–62040, noVNC 5900, Moonlight ports — see `docs/ARCHIVED_EXPERIMENTS.md`.

### 3.2 Wire protocol (browser ↔ gateway)

Single WSS connection per player: `wss://<host>:6081/stream` (or 6082).

**Browser → server (JSON):**

| Message | Purpose |
|---------|---------|
| `start` | Connect with transport settings |
| `reconfigure` | Live settings change |
| `ping` | RTT measurement |
| `mousemove`, `mousedown`, `mouseup`, `wheel` | Pointer input |
| `keydown`, `keyup`, `keyup_all` | Keyboard |

**Server → browser (JSON):**

| Message | Purpose |
|---------|---------|
| `hello`, `ready` | Session + active settings |
| `video` | Base64 H.264/HEVC bitstream |
| `audio` | Base64 Opus or PCM |
| `pong` | RTT reply |

Video/audio use base64 in JSON (~33% overhead — known improvement area).

### 3.3 NAS directory layout

```text
/volume2/Data/App_Development/ra2-lan-party/
  assets-game2/       ← ASSETS_DIR (NOT in backup — copyrighted)
  prefixes/           ← Wine state + serials (IN backup)
  project/            ← This repo (IN backup)
  logs/player1,2/     ← Diagnostics (IN backup)
  tls/                ← HTTPS certs (IN backup)
  backups/            ← backup-golden-master.sh output
  .env                ← Secrets (IN backup — protect archive)
```

### 3.4 Key files and scripts

| Path | Role |
|------|------|
| `compose.yaml` | Two-player base, shared env anchor |
| `compose.https.yaml` | TLS mounts |
| `compose.ultra.yaml` | Ultra overlay, VA-API devices |
| `container/Dockerfile.ultra` | Image build |
| `container/ra2-stream-gateway.py` | HTTPS/WSS server, input via xdotool |
| `container/stream-helper.c` | GStreamer capture/encode |
| `container/remote-ultra/ultra-play.js` | Browser client |
| `scripts/redeploy-ultra.sh` | Sync + recreate both players |
| `scripts/restart-audio-ultra.sh` | Pulse → game → gateway |
| `scripts/validate-env.sh` | Pre-flight `.env` |
| `scripts/backup-golden-master.sh` | Image + runtime backup (no game files) |
| `scripts/sync-to-nas.sh` | Mac → NAS rsync/tar |
| `tests/test_project_contracts.py` | 77 contract tests |

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

# 4. Build + deploy both players
RA2_COMPOSE_ULTRA=1 sh scripts/redeploy-ultra.sh

# 5. Verify
python3 -m pytest tests/ -q
curl -sk -o /dev/null -w "%{http_code}\n" https://127.0.0.1:6081/
curl -sk -o /dev/null -w "%{http_code}\n" https://127.0.0.1:6082/
```

**From Mac after edits:**

```bash
NAS_HOST=MediaServer2 RA2_ULTRA_BUILD=0 sh scripts/redeploy-ultra.sh
```

**Manual play test:** connect, audio, game mode (fullscreen + lock), dual cursors, multiplayer LAN discovery, 10+ min stable gameplay.

---

## 5. Known bugs and fixes

| # | Issue | Fix |
|---|-------|-----|
| 1 | Map load freeze | Never rewrite game INI in `start_helper()` — only at gamemd launch |
| 2 | HEVC missing from menu | Leave `ULTRA_STREAM_CODEC_LOCK` empty |
| 3 | Stale code after sync | Always `--force-recreate` containers |
| 4 | SSH LAN timeout | Use `NAS_HOST=MediaServer2` (DDNS) |
| 5 | Player 2 URL dead | Deploy both players; forward TCP 6082 |
| 6 | `VNC_PASSWORD` missing | Add shared `VNC_PASSWORD` to `.env` |
| 7 | Silent audio after Pulse restart | `restart-audio-ultra.sh` |
| 8 | gamemd crash / lockup | CPU pin game cores 0/1, encode 2/3 |
| 9 | VA-API black video | Remove iHD; use `LIBVA_DRIVER_NAME=i965` |
| 10 | VAProfileNone on DSM | `enable-host-transcode.sh` |
| 11 | Low RAM OOM | `two-player-low` profile; upgrade RAM |
| 12 | HEVC decode fail in browser | Auto-fallback H265_10 → H265 → H264 |
| 13 | Old client cached | Hard refresh; bump `SETTINGS_VERSION` |
| 14 | WebCodecs blocked on HTTP | Use HTTPS overlay |
| 15 | Multiplayer LAN fail | `wsock32.dll` + bridge network |
| 16 | Game mode flicker / disconnect | Don't exit game mode on `blur`; use `gameModeBusy` grace |
| 17 | Game mode instant kick-out | Request FS + pointer lock same user gesture; no await between |
| 18 | Mouse dead in game mode | Document-level capture listeners (lock targets `#gameSurface`) |
| 19 | Stuck **L** key on Ctrl+Alt+L | Shortcut handled in capture phase; never forwarded; `releasePressedKeys()` on enter |
| 20 | redeploy websockify false positive | Verify with `curl` + `docker ps` — container may still be healthy |

---

## 6. Benchmarks and improvements

### 6.1 Measured on DS225+ (J4125, production)

| Metric | Value |
|--------|-------|
| Ultra image size | ~3.41 GB |
| Per-container RAM | ~240–260 MB of 512 MB limit |
| `gamemd.exe` CPU | ~75–100% of one core (pinned) |
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
5. Game INI sync at launch only — not during helper start
6. Opus 48 kHz end-to-end
7. Full input forwarding — no broad key guards
8. Game mode: `#gameSurface` for both FS and pointer lock; document-level mouse capture when locked
9. Ctrl+Alt+L never forwarded as game keydown

---

## 8. Backup and restore

### 8.1 Create backup (no game files)

```bash
# On NAS
cd /volume2/Data/App_Development/ra2-lan-party/project
sh scripts/backup-golden-master.sh

# From Mac
NAS_HOST=MediaServer2 sh scripts/backup-golden-master.sh
```

Output: `/volume2/Data/App_Development/ra2-lan-party/backups/golden-master-YYYYMMDD-HHMMSS/`

- `ra2-lan-party-ultra-image.tar.gz` — Docker image
- `ra2-golden-master-runtime.tar.gz` — project, prefixes, tls, logs, .env
- **Excludes:** `assets/`, `assets-game1/`, `assets-game2/`, `RA2Yuri_Game1/`

### 8.2 Restore sketch

```bash
docker load < ra2-lan-party-ultra-image.tar.gz
tar -xzf ra2-golden-master-runtime.tar.gz -C /volume2/Data/App_Development/ra2-lan-party
# Re-stage game files to assets-game2 separately
RA2_COMPOSE_ULTRA=1 sh scripts/redeploy-ultra.sh
```

---

## 9. Verification

```bash
python3 -m pytest tests/ -q                           # expect 77 passed
RA2_COMPOSE_ULTRA=1 sh scripts/check-ultra-ready.sh
curl -sk -o /dev/null -w "6081=%{http_code}\n" https://peterjfrancoiii2.synology.me:6081/
curl -sk -o /dev/null -w "6082=%{http_code}\n" https://peterjfrancoiii2.synology.me:6082/
docker exec ra2-player-1 sh -lc 'pgrep -x gamemd.exe | xargs -r taskset -pc'
```

---

## 10. Document index

| Doc | Use |
|-----|-----|
| **This file** | Authoritative golden master |
| `README.md` | Repo entry point |
| `docs/ULTRA_LIGHT_ARCH_STREAMING.md` | Transport menu shorthand |
| `docs/HTTPS.md` | TLS options |
| `docs/NAS_DEPLOY_STATUS.md` | Operator snapshot |
| `docs/ARCHIVED_EXPERIMENTS.md` | Deprecated paths |

**Lock date:** June 2026. Do not deploy archived compose overlays on production NAS.
