# NAS Deploy Status

**Golden master tag:** `golden-master-2026-06` (June 2026)  
**Host:** MediaServer2 / `192.168.0.193` / `peterjfrancoiii2.synology.me`

## Production (verified)

| Item | Status |
|------|--------|
| Image | `ra2-lan-party:ultra` |
| `ra2-player-1` | Port 6081 · healthy |
| `ra2-player-2` | Port 6082 · healthy |
| Assets | `assets-game2` |
| Client | `SETTINGS_VERSION=32` |
| Transport | H.265 10-bit · 2 Mbps · Opus 64k · 60 Hz mouse |
| Game mode | Fullscreen + pointer lock + dual lag cursors |

## URLs

```text
Player 1: https://peterjfrancoiii2.synology.me:6081/
Player 2: https://peterjfrancoiii2.synology.me:6082/
```

## Operator commands

```bash
cd /volume2/Data/App_Development/ra2-lan-party/project
RA2_COMPOSE_ULTRA=1 sh scripts/redeploy-ultra.sh
sudo sh scripts/restart-audio-ultra.sh ra2-player-1
sh scripts/backup-golden-master.sh
python3 -m pytest tests/ -q
```

From Mac:

```bash
NAS_HOST=MediaServer2 RA2_ULTRA_BUILD=0 sh scripts/redeploy-ultra.sh
NAS_HOST=MediaServer2 sh scripts/backup-golden-master.sh
```

Full reference: [`docs/GOLDEN_MASTER.md`](GOLDEN_MASTER.md)
