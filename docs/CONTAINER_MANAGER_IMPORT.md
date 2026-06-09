# Container Manager Import (optional)

If SSH Docker access is inconvenient, you can still launch from Synology Container Manager after assets are ready.

## Steps

1. Open **Container Manager** on DSM.
2. Go to **Project** → **Create**.
3. Set project path to:

```text
/volume2/Data/App_Development/ra2-lan-party/project
```

4. Use the existing `compose.yaml` in that folder.
5. Ensure `.env` exists beside `compose.yaml`.
6. Build and start the project from the DSM UI.

## Notes

- Game files are not baked into the image. They must exist in `../assets` before containers start.
- Browser URLs remain:
  - `http://192.168.0.193:6081/`
  - `http://192.168.0.193:6082/`
