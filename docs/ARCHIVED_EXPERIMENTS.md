# Archived Experiments (not golden master)

The **production path** is documented in `docs/GOLDEN_MASTER.md`: ultra browser streaming on ports `6081`/`6082` with `RA2_COMPOSE_ULTRA=1`.

The files below remain in the repository for reference and contract tests but are **not** part of the locked June 2026 golden master. Do not deploy them on the production NAS unless you are explicitly experimenting.

## Archived streaming profiles

| Profile | Compose / scripts | Docs |
|---------|-------------------|------|
| Legacy WebRTC `remote.html` | `compose.webrtc.yaml`, `compose.webrtc-host.yaml`, `compose.webrtc-udp.yaml`, `compose.webrtc-uinput.yaml` | §WebRTC in `docs/DEPLOY_SYNOLOGY.md` |
| Moonlight + Wolf/Sunshine | `compose.wolf.yaml`, `compose.sunshine.yaml`, `compose.moonlight-uinput.yaml` | `docs/MOONLIGHT_EXPERIMENT.md` |
| Selkies / Webtop | `compose.selkies-experiment.yaml` | `docs/SELKIES_EXPERIMENT.md` |
| Tailscale WAN Moonlight | `compose.tailscale.yaml` | `docs/TAILSCALE.md` |
| noVNC-only base image | `container/Dockerfile`, `container/supervisord.conf`, `compose.yaml` without ultra overlay | `docs/HTTPS.md` (vnc.html paths) |
| VA-API transcode overlay | `compose.transcode.yaml` | `docs/DEPLOY_SYNOLOGY.md` |
| RAM debug player | `compose.ultra.yaml` profile `ra2-player-dev`, `scripts/dev-ram-ultra.sh` | `scripts/dev-ram-ultra.sh` header |

## Archived container modules (ultra image does not use these at runtime)

- `container/remote/remote.html`, `remote-play.js` — WebRTC client
- `container/webrtc-media.py`, `webrtc-media-helper.c`, `start-webrtc.sh`
- `container/audio-proxy.sh`, `latency-proxy.sh`, `start-websockify.sh`, `start-x11vnc.sh`
- `container/patch-novnc.sh`, `cursor-lock.js`, `latency-overlay.js`

These may still exist inside older `ra2-lan-party:latest` images built from `container/Dockerfile`; the ultra image uses `Dockerfile.ultra` and `supervisord.ultra.conf` instead.

## Cleaning up on the NAS

After locking golden master, remove stale artifacts:

```bash
sudo sh scripts/cleanup-golden-master.sh
```

This removes stopped orphan containers, dangling images, and documents how to drop unused `ra2-lan-party:latest` if only `:ultra` is deployed.
