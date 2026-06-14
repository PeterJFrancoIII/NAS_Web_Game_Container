# Game Assets (not included in repo)

The runtime does not include copyrighted game files. Stage your legally owned installations on the NAS separately.

## Red Alert 2 / Yuri's Revenge

```text
/volume2/Data/App_Development/ra2-lan-party/assets-game2/
```

Minimum expected files:

- `RA2MD.exe` for Yuri's Revenge, or set `GAME_EXE=RA2.exe` in `.env` for base Red Alert 2.
- Red Alert 2 / Yuri's Revenge `.mix`, `.ini`, and support files from your installation.
- `ddraw.dll` and `ddraw.ini` from cnc-ddraw.
- `wsock32.dll` from an IPX-to-UDP wrapper compatible with Red Alert 2 LAN play.
- `ipxwrapper.ini` if your wrapper reads it (template provided in `../config`).

Copy the templates in `../config` into the assets directory after backing up any existing files you want to preserve.

## Age of Empires II (1999)

Default mount (override with `AOE2_ASSETS_HOST` in `.env`):

```text
/volume2/Data/Games/2 Unpacked - Ready to Play/Age of Empires 2/
```

Requires `EMPIRES2.EXE` and game data. English language overlay: run `scripts/install-aoe2-english-language.sh` if needed.

## StarCraft + Brood War

Default mounts (override with `SC_*_HOST` in `.env`):

```text
/volume2/Data/Games/2 Unpacked - Ready to Play/StarCraft/     ← SC_ASSETS_HOST
/volume2/Data/Games/1 Packed - Compressed/StarCraft & Brood War/  ← SC_DISC_HOST (disc images)
```

Unpack from disc images on the NAS:

```bash
sh scripts/unpack-starcraft-broodwar.sh
```

Requires `StarCraft.exe`, `StarCraft.mpq`, `BroodWar.mpq`, and `storm.dll` in the unpacked tree.

## Compose mapping (inside container)

| Host env | Container path | Game |
|----------|----------------|------|
| `ASSETS_DIR` | `/home/commander/game_assets` | RA2 |
| `AOE2_ASSETS_HOST` | `/home/commander/aoe2_assets` | AoE II |
| `SC_ASSETS_HOST` | `/home/commander/sc_assets` | StarCraft |

Profiles and preflight checks are defined in `config/games.json`.
