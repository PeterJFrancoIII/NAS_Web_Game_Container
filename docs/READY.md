# Ready Checklist

Use this before calling the ultra golden master production-ready. Full descriptor: `docs/GOLDEN_MASTER.md`.

## Automated

On your Mac or the NAS project folder:

```bash
sh scripts/verify-ready.sh
python3 -m pytest tests/ -q
```

On the NAS after assets are copied:

```bash
sh scripts/validate-env.sh
sh scripts/ingest-assets.sh
RA2_COMPOSE_ULTRA=1 sh scripts/redeploy-ultra.sh
RA2_COMPOSE_ULTRA=1 sh scripts/check-ultra-ready.sh
```

## Manual gates

- [ ] Legally owned RA2/Yuri install copied to `assets/`
- [ ] `ddraw.dll` and `wsock32.dll` present in `assets/`
- [ ] `.env` passwords changed from placeholders; `RA2_COMPOSE_ULTRA=1`
- [ ] Unique `PLAYER1_SERIAL` and `PLAYER2_SERIAL` set
- [ ] `ra2-lan-party:ultra` image built on NAS
- [ ] Both containers healthy
- [ ] `https://192.168.0.193:6081/` opens ultra play page (Player 1)
- [ ] Audio audible after clicking **Enable audio**
- [ ] LAN lobby sees both instances
- [ ] Remote DDNS works on `:6081` / `:6082` (router forwards)

## Current staged state

Project root on NAS:

```text
/volume2/Data/App_Development/ra2-lan-party
```
