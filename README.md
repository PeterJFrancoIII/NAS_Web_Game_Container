# Synology RA2 Arch LAN Party — Golden Master

**Tag:** `golden-master-2026-06` · **Lock:** June 2026

Two-player Red Alert 2 / Yuri's Revenge on Synology DS225+, streamed to Chromium over **one HTTPS port per player** via WebCodecs + WSS.

> **Read first:** [`docs/GOLDEN_MASTER.md`](docs/GOLDEN_MASTER.md) — full replication guide for LLM agents and developers (hardware, ports, transport, bugs, benchmarks, backup).

## Play URLs

| Player | LAN | Remote |
|--------|-----|--------|
| 1 | `https://192.168.0.193:6081/` | `https://peterjfrancoiii2.synology.me:6081/` |
| 2 | `https://192.168.0.193:6082/` | `https://peterjfrancoiii2.synology.me:6082/` |

Router: forward **TCP 6081 + 6082**. Hard-refresh after client updates.

## Stack at a glance

| | |
|---|---|
| **Host** | Synology DS225+ · Intel J4125 · 4 cores · i965 VA-API |
| **Image** | `ra2-lan-party:ultra` |
| **Compose** | `compose.yaml` + `compose.https.yaml` + `compose.ultra.yaml` |
| **Flag** | `RA2_COMPOSE_ULTRA=1` |
| **Client** | `container/remote-ultra/` · `SETTINGS_VERSION=32` |
| **Tests** | `python3 -m pytest tests/ -q` (77 passed) |

**Production:** **Ultra Arch Browser** streaming only. **Not production:** noVNC, WebRTC, Moonlight — [`docs/ARCHIVED_EXPERIMENTS.md`](docs/ARCHIVED_EXPERIMENTS.md).

## Architecture

```text
Chromium  ←─ HTTPS/WSS :6081|:6082 ─→  ra2-stream-gateway.py
                                              ↓
                                    stream-helper (VA-API, cores 2–3)
                                              ↓
                                    Xvfb + Wine/gamemd.exe (core 0 or 1)
```

Both players share identical config; **only serial keys and Wine prefixes differ**.

## Golden transport defaults

| Layer | Value |
|-------|-------|
| Video | H.265 10-bit · 24 fps · 2.0 Mbps · GPU scale |
| Audio | Opus 48 kHz · 64 kbps |
| Input | 60 Hz mouse · full keys/buttons/wheel |
| Display | 960×720 @ 24-bit |
| Game mode | Fullscreen + pointer lock · dual lag cursors (white local / amber remote) |

## Replicate (minimal)

```bash
cd /volume2/Data/App_Development/ra2-lan-party/project
cp .env.example .env          # PLAYER1/2_SERIAL, VNC_PASSWORD, ASSETS_DIR
sh scripts/validate-env.sh
sh scripts/prepare-nas.sh
# Stage game files to assets-game2 separately (not in repo)
RA2_COMPOSE_ULTRA=1 sh scripts/redeploy-ultra.sh
```

From Mac: `NAS_HOST=MediaServer2 RA2_ULTRA_BUILD=0 sh scripts/redeploy-ultra.sh`

Or generic bootstrap: `sh scripts/bootstrap-nas.sh launch`

## Ports (production — TCP only to internet)

| Port | Use |
|------|-----|
| 6081 | Player 1 HTTPS + WSS `/stream` |
| 6082 | Player 2 HTTPS + WSS `/stream` |

Game multiplayer UDP stays on Docker bridge `172.22.20.11` ↔ `172.22.20.12` (not forwarded).

## Key scripts

| Script | Purpose |
|--------|---------|
| `scripts/redeploy-ultra.sh` | Deploy both players |
| `scripts/restart-audio-ultra.sh` | Fix audio after Pulse restart |
| `scripts/backup-golden-master.sh` | Backup image + runtime (no game files) |
| `scripts/validate-env.sh` | Pre-flight `.env` |
| `scripts/sync-to-nas.sh` | Mac → NAS sync |

## Backup

```bash
NAS_HOST=MediaServer2 sh scripts/backup-golden-master.sh
```

Creates `/volume2/.../ra2-lan-party/backups/golden-master-<timestamp>/` with Docker image + project/prefixes/tls/logs. **Excludes** `assets*` and game installers.

## Known issues (summary)

See full table in [`docs/GOLDEN_MASTER.md` §5](docs/GOLDEN_MASTER.md). Top items:

- Map freeze → don't rewrite INI during stream start
- Player 2 down → deploy both; forward 6082
- Game mode → `#gameSurface` FS+lock; document-level mouse capture
- Stuck L on Ctrl+Alt+L → shortcut not forwarded to game
- Stale client → hard refresh

## Benchmarks (J4125, measured)

| | |
|---|---|
| stream-helper CPU | ~12–16% of one core (GPU path) |
| gamemd CPU | ~75–100% of one core (pinned) |
| GPU vs CPU convert | −40% helper CPU |

Improvements available: binary WSS, `vah264lpenc`, RAM upgrade — see golden master §6.

## Hardware requirements

- Synology with Docker + `/dev/dri` (`RENDER_GID=937`)
- Intel Quick Sync / VA-API (i965 on Gemini Lake)
- 6+ GB RAM recommended for two players
- Chromium/Chrome/Edge on clients

## Legal

No copyrighted game files, serials, or third-party DLLs are included in this repo.

## Documentation map

| Document | Content |
|----------|---------|
| [`docs/GOLDEN_MASTER.md`](docs/GOLDEN_MASTER.md) | **Authoritative** — everything needed to reproduce |
| [`docs/ULTRA_LIGHT_ARCH_STREAMING.md`](docs/ULTRA_LIGHT_ARCH_STREAMING.md) | Transport menu |
| [`docs/HTTPS.md`](docs/HTTPS.md) | TLS / reverse proxy |
| [`docs/NAS_DEPLOY_STATUS.md`](docs/NAS_DEPLOY_STATUS.md) | Last deploy snapshot |
| [`docs/DEPLOY_SYNOLOGY.md`](docs/DEPLOY_SYNOLOGY.md) | Extended NAS guide |

## Container build

```bash
docker compose --env-file .env \
  -f compose.yaml -f compose.https.yaml -f compose.ultra.yaml \
  build ra2-player-1 ra2-player-2
```

Wine: **10.8 amd64 package + win32 prefix + multilib** — do not change without gameplay validation.

**Archived legacy fallback** (not golden master): WebRTC, Moonlight (`docs/MOONLIGHT_EXPERIMENT.md`, `compose.sunshine.yaml`), Tailscale (`docs/TAILSCALE.md`). Optional transcode overlay: `RA2_COMPOSE_TRANSCODE=1`.
