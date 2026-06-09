# Synology RA2 Arch LAN Party

This project prepares a Synology DS225+ to host two Red Alert 2 / Yuri's Revenge game instances in lightweight Arch Linux Docker containers. Each player connects from a web browser through noVNC, while the game instances see each other on a static private Docker LAN.

## What It Builds

- `ra2-player-1`: Arch Linux + Wine + Xvfb/noVNC, internal IP `172.22.20.11`, browser port `6081`.
- `ra2-player-2`: Arch Linux + Wine + Xvfb/noVNC, internal IP `172.22.20.12`, browser port `6082`.
- Shared read-only assets folder for legal game files.
- Separate persistent Wine prefixes for each player.

The runtime avoids full VMs and desktop environments. It uses `Xvfb`, `openbox`, `x11vnc`, `websockify`, and noVNC to keep memory use low on the DS225+.

## Legal And Asset Boundary

No copyrighted game files, serials, or third-party compatibility DLLs are included. You must supply your own legally owned Red Alert 2 / Yuri's Revenge files, plus the compatibility wrappers you choose to use.

Expected NAS asset path:

```text
/volume2/Data/App_Development/ra2-lan-party/assets
```

## Quick Start

On the Synology:

```bash
cd /volume2/Data/App_Development
mkdir -p ra2-lan-party/project
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
docker compose --env-file .env up -d --build
```

Optional hardware video-transcoding tooling is available through `compose.transcode.yaml`. It grants `/dev/dri` access for FFmpeg/GStreamer VA-API tests while leaving the default noVNC path unchanged:

```bash
docker compose --env-file .env -f compose.yaml -f compose.transcode.yaml up -d --build
```

Connect:

```text
Player 1: http://192.168.0.193:6081/
Player 2: http://192.168.0.193:6082/
```

See `docs/DEPLOY_SYNOLOGY.md` for the full deployment guide.

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
sh scripts/run-tests.sh
```

The tests validate each logical layer of the project: Synology paths, environment defaults, Compose topology/static IPs, browser ports, script syntax, runtime startup contract, required asset checks, noVNC display pipeline, game config templates, NAS folder preparation, and deployment documentation.

## Important Files

- `compose.yaml`: Synology two-player stack.
- `.env.example`: deployment values to copy into `.env`.
- `container/Dockerfile`: minimal Arch Linux Wine/noVNC image.
- `container/entrypoint.sh`: first-run Wine prefix initialization and registry setup.
- `container/supervisord.conf`: process supervision for display, browser bridge, and game.
- `config/`: game configuration templates for the assets folder.
- `scripts/prepare-nas.sh`: NAS directory preparation script.
