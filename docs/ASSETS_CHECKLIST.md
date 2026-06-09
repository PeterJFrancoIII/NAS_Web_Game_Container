# Assets Checklist

Use this while preparing game files. The NAS stack is already staged; containers only start after these items exist in:

```text
/volume2/Data/App_Development/ra2-lan-party/assets
```

## Required

| File | Source | Notes |
|---|---|---|
| `RA2MD.exe` | Your legal Yuri's Revenge install | Or set `GAME_EXE=RA2.exe` in `.env` |
| Game `.mix` / support files | Same install | Copy the full game folder contents |
| `ddraw.dll` | cnc-ddraw | Place beside the game executable |
| `ddraw.ini` | This project's `config/` | Already copied unless you replace it |
| `wsock32.dll` | IPX-to-UDP wrapper | Required for LAN discovery between containers |

## Recommended

| File | Purpose |
|---|---|
| `RA2.ini` | Video/network defaults |
| `RA2MD.ini` | Video/network defaults |
| `ipxwrapper.ini` | Only if your wrapper reads it |

## When files are ready

On the NAS:

```bash
cd /volume2/Data/App_Development/ra2-lan-party/project
sh scripts/ingest-assets.sh /path/to/your/ra2-folder
sh scripts/bootstrap-nas.sh
```

Or copy manually into `assets/`, then run `bootstrap-nas.sh`.
