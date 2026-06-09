# Assets Folder Contents

The runtime does not include copyrighted game files. Put your legally owned Red Alert 2 / Yuri's Revenge installation files in the NAS assets directory:

```text
/volume2/Data/App_Development/ra2-lan-party/assets
```

Minimum expected files:

- `RA2MD.exe` for Yuri's Revenge, or set `GAME_EXE=RA2.exe` in `.env` for base Red Alert 2.
- Red Alert 2 / Yuri's Revenge `.mix`, `.ini`, and support files from your installation.
- `ddraw.dll` and `ddraw.ini` from cnc-ddraw.
- `wsock32.dll` from an IPX-to-UDP wrapper compatible with Red Alert 2 LAN play.
- `ipxwrapper.ini` if your wrapper reads it (template provided in `../config`).

Copy the templates in `../config` into the assets directory after backing up any existing files you want to preserve.
