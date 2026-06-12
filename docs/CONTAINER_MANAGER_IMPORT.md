# Container Manager Import (optional)

If SSH Docker access is inconvenient, you can still launch from Synology Container Manager after assets are ready.

## Steps

1. Open **Container Manager** on DSM.
2. Go to **Project** → **Create**.
3. Set project path to:

```text
/volume2/Data/App_Development/ra2-lan-party/project
```

4. Use `compose.yaml` with overlays — in `.env` set `RA2_COMPOSE_ULTRA=1` for the golden-master browser path.
5. Ensure `.env` exists beside `compose.yaml` (copy from `.env.example`).
6. Build and start the project from the DSM UI (include `compose.https.yaml` and `compose.ultra.yaml` if the UI supports multiple compose files; otherwise use SSH `scripts/redeploy-ultra.sh`).

## Notes

- Game files are not baked into the image. They must exist in `../assets` before containers start.
- Production browser URLs (HTTPS):
  - `https://192.168.0.193:6081/` (player 1)
  - `https://192.168.0.193:6082/` (player 2)
- See `docs/GOLDEN_MASTER.md` for the full production descriptor.
