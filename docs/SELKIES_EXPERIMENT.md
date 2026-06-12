# Selkies / Wayland Experiment (DS225+)

> **Archived / rejected (June 2026):** Production uses ultra browser streaming (`docs/GOLDEN_MASTER.md`). Selkies was too heavy for the DS225+.

This was an **optional side-by-side experiment**.

## Why experiment?

Selkies runs a Wayland compositor with lower capture overhead than scraping X11 via `ximagesrc`. On DS225+ (Intel UHD 600 / Gemini Lake), it may reduce glass-to-glass latency — but RA2/Wine is X11-based today, so compatibility must be measured, not assumed.

## Deploy

```bash
cd /volume2/Data/App_Development/ra2-lan-party/project
mkdir -p data/selkies-experiment/config
docker compose --env-file .env -f compose.selkies-experiment.yaml up -d
```

Open:

```text
https://<NAS_LAN_IP>:6101
```

Default ports are `6100` (HTTP) and `6101` (HTTPS) to avoid clashing with RA2 (`6081-6086`, `62001-62040`).

Set `SELKIES_PASSWORD` in `.env` before exposing the experiment.

## Compare against current WebRTC path

Measure the same scenario on both stacks:

| Metric | RA2 WebRTC (`remote.html`) | Selkies experiment |
|--------|---------------------------|-------------------|
| Glass-to-glass latency | click-to-pixel (manual or high-speed camera) | same |
| Encode path | `vah264enc` + `ximagesrc` | Selkies VA-API Wayland capture |
| Browser stability (Safari) | canvas + H264 | Selkies WebRTC / WebCodecs |
| CPU load during play | `docker stats` | `docker stats` |
| Helper/orphan processes | `pgrep -af webrtc-media-helper` | N/A |

Run host checks before sessions:

```bash
sh scripts/check-low-latency-host.sh
sh scripts/compare-selkies-webrtc.sh
```

## RA2 under Selkies (compatibility test)

1. Install Wine and copy RA2 assets into the experiment desktop (or mount read-only assets).
2. Launch `RA2MD.exe` under the Selkies desktop session.
3. Note rendering bugs (Gemini Lake may need `MESA_LOADER_DRIVER_OVERRIDE=zink` and `INTEL_DEBUG=norbc`, already set in compose).

## Go / no-go

Promote Selkies only if **all** are true on DS225+ hardware:

- RA2 launches and plays acceptably under the Selkies desktop.
- Measured latency is lower than the stable H264 WebRTC preset.
- Safari (or your target browser) remains stable for a full play session.

Otherwise keep Selkies documented as an experiment and retain `WEBRTC_LATENCY_PRESET=stable` for production.

## Tear down

```bash
docker compose -f compose.selkies-experiment.yaml down
```

This does not affect `ra2-player-1` or `ra2-player-2`.
