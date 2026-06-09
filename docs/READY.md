# Ready Checklist

Use this before calling the stack production-ready.

## Automated

On your Mac or the NAS project folder:

```bash
sh scripts/verify-ready.sh
sh scripts/bootstrap-nas.sh prepare
```

On the NAS after assets are copied:

```bash
sh scripts/validate-env.sh
sh scripts/ingest-assets.sh
sudo /usr/local/bin/docker compose --env-file .env up -d
```

## Manual gates

- [ ] Legally owned RA2/Yuri install copied to `assets/`
- [ ] `ddraw.dll` and `wsock32.dll` present in `assets/`
- [ ] `.env` passwords changed from placeholders
- [ ] Unique `PLAYER1_SERIAL` and `PLAYER2_SERIAL` set
- [ ] Docker image built on NAS
- [ ] Both containers healthy
- [ ] `http://192.168.0.193:6081/` opens Player 1
- [ ] `http://192.168.0.193:6082/` opens Player 2
- [ ] LAN lobby sees both instances

## Current staged state (without game files)

Everything except game binaries and Docker sudo build is prepared under:

```text
/volume2/Data/App_Development/ra2-lan-party
```
