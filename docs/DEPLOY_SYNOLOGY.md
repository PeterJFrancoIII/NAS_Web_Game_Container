# Synology DS225+ Deployment

This project targets the audited DS225+ layout:

- NAS hostname: `MediaServer2`
- DSM route: `ovs_eth0` through `192.168.0.1`
- NAS LAN IP: `192.168.0.193`
- Persistent app root: `/volume2/Data/App_Development/ra2-lan-party`

The containers use an internal Docker bridge, not macvlan. Player 1 is always `172.22.20.11`, Player 2 is always `172.22.20.12`, and browsers connect through NAS ports `6081` and `6082`.

## 1. Copy Project To NAS

Copy this project into:

```text
/volume2/Data/App_Development/ra2-lan-party/project
```

## 2. Prepare NAS Folders

SSH to the NAS, then run the prep script from the copied project:

```bash
cd /volume2/Data/App_Development/ra2-lan-party/project
sh scripts/prepare-nas.sh
```

Run this before `docker compose up`. It creates assets/prefixes/logs with UID `1000` ownership so Wine can write its prefixes.

## 3. Add Game Assets

Copy your legally owned Red Alert 2 / Yuri's Revenge installation files into:

```text
/volume2/Data/App_Development/ra2-lan-party/assets
```

Also place these compatibility files in that same assets folder:

- `ddraw.dll` and `ddraw.ini` from cnc-ddraw.
- `wsock32.dll` from an IPX-to-UDP wrapper that supports Red Alert 2 LAN play.
- `ipxwrapper.ini` from this project's `config` folder if your wrapper uses it.
- `RA2.ini` and `RA2MD.ini` templates from this project's `config` folder, unless you already have tuned versions.

The container validates `RA2MD.exe` or your configured `GAME_EXE`, `ddraw.dll`, `ddraw.ini`, and `wsock32.dll` at startup. Compatibility DLLs and config files are refreshed into each Wine prefix on restart, so wrapper updates do not require deleting the whole prefix.

This repository intentionally does not provide game binaries, serials, or third-party DLL downloads.

LAN multiplayer depends on the wrapper, not just static IPs. Confirm both containers can see `172.22.20.11` and `172.22.20.12`, and tune `ipxwrapper.ini` for the wrapper you install.

## 4. Configure Environment

On the NAS:

```bash
cd /volume2/Data/App_Development/ra2-lan-party/project
cp .env.example .env
vi .env
sh scripts/validate-env.sh
```

Change at least:

- `PLAYER1_VNC_PASSWORD`
- `PLAYER2_VNC_PASSWORD`
- `PLAYER1_SERIAL`
- `PLAYER2_SERIAL`

Use two unique serial values from legitimately owned installations/copies. Duplicate serials can prevent LAN multiplayer.

Optional staged workflow before assets arrive:

```bash
sh scripts/bootstrap-nas.sh prepare
sh scripts/bootstrap-nas.sh build
```

## 5. Start The Stack

Running two Wine game instances on the stock 2 GB DS225+ is an OOM risk, especially alongside Plex or other containers. The research recommends expanding RAM before treating this as a stable two-player setup.

```bash
cd /volume2/Data/App_Development/ra2-lan-party/project
docker compose --env-file .env up -d --build
```

Verify:

```bash
docker compose ps
docker network inspect ra2-lan-party_ra2_lan
docker logs --tail=100 ra2-player-1
docker logs --tail=100 ra2-player-2
```

Expected internal addresses:

```text
ra2-player-1: 172.22.20.11
ra2-player-2: 172.22.20.12
```

## 6. Optional VA-API Transcoding Tooling

The runtime image includes FFmpeg, GStreamer, and VA-API packages for Intel hardware-encoding experiments. The normal stack still uses noVNC/RFB; H.265/WebCodecs or WebRTC streaming requires a separate transport layer and client renderer.

If you want to test hardware encoder access from the Arch containers, first confirm the NAS exposes DRM devices:

```bash
ls -lah /dev/dri
stat -c '%g %n' /dev/dri/renderD128 /dev/dri/card0
```

On the target DS225+ test system, `/dev/dri/renderD128` is owned by group `937` (`videodriver`), so `RENDER_GID=937` is the expected value. `card0` may remain `root:root` mode `600`; VA-API encoding only needs the render node.

The DS225+ uses an Intel J4125 (Gemini Lake), which supports hardware H.264 and HEVC encoding. On this CPU, the modern `iHD` driver can open successfully but only report `VAProfileNone`, which hides the usable hardware encoders. Use `LIBVA_DRIVER_NAME=i965` instead.

Set `RENDER_GID`, `VIDEO_GID`, `DRI_DEVICE`, and `LIBVA_DRIVER_NAME` in `.env` if the defaults do not match your NAS. Then start with the overlay:

```bash
docker compose --env-file .env -f compose.yaml -f compose.transcode.yaml up -d --build
```

Verify VA-API visibility:

```bash
sudo sh scripts/check-transcode.sh ra2-player-1
```

On Synology, Docker usually requires one `sudo` prompt for the whole script. The script does not call `sudo` again internally once it is already running as root.

If you prefer direct commands, use:

```bash
sudo /usr/local/bin/docker exec ra2-player-1 sh -lc 'LIBVA_DRIVER_NAME=i965 vainfo --display drm --device /dev/dri/renderD128'
sudo /usr/local/bin/docker exec ra2-player-1 sh -lc '/usr/bin/ffmpeg -hide_banner -encoders | grep -i vaapi'
```

Healthy output should include H.264 and HEVC VA-API encode profiles in `vainfo`, plus passing `h264_vaapi` and `hevc_vaapi` smoke tests from `scripts/check-transcode.sh`.

If `vainfo` only reports `VAProfileNone` on the DS225+, check the Synology host i915 firmware state:

```bash
sudo cat /sys/kernel/debug/dri/0/gt/uc/guc_info
sudo cat /sys/kernel/debug/dri/0/gt/uc/huc_info
```

When GuC/HuC are disabled by DSM, containers can see `/dev/dri` and FFmpeg can list VA-API encoders, but actual hardware encode will still fail until the host exposes media profiles.

The zero-copy `kmsgrab` examples in the research need a real KMS/DRM display plane. The current game desktop uses `Xvfb`, so those commands are preparation for a future streaming backend rather than a drop-in replacement for noVNC.

## 7. Connect Players

From client browsers on the LAN:

```text
Player 1: http://192.168.0.193:6081/
Player 2: http://192.168.0.193:6082/
```

Use the VNC passwords from `.env`.

If the NAS uses the secondary LAN IP, these may also work:

```text
Player 1: http://192.168.0.194:6081/
Player 2: http://192.168.0.194:6082/
```

## 8. Synology Firewall

If DSM firewall is enabled, allow:

- Browser access from your LAN to TCP `6081` and `6082` on the NAS.
- Container subnet `172.22.20.0/24` so the two game instances can exchange UDP LAN discovery/game traffic.

Do not forward `6081` or `6082` from the internet unless you add stronger access controls outside this stack.

## 9. Troubleshooting

If noVNC opens but the game is missing, inspect assets:

```bash
ls -lah /volume2/Data/App_Development/ra2-lan-party/assets
docker logs --tail=200 ra2-player-1
```

If Wine cannot write its prefix, fix permissions:

```bash
sudo chown -R 1000:1000 /volume2/Data/App_Development/ra2-lan-party/prefixes
sudo chmod -R u+rwX,g+rwX /volume2/Data/App_Development/ra2-lan-party/prefixes
```

If the game runs but LAN discovery fails:

```bash
docker exec ra2-player-1 ip addr
docker exec ra2-player-2 ip addr
docker network inspect ra2-lan-party_ra2_lan
```

Then confirm `wsock32.dll` is present in both copied game directories:

```bash
docker exec ra2-player-1 ls -lah /home/commander/.wine/drive_c/RA2/wsock32.dll
docker exec ra2-player-2 ls -lah /home/commander/.wine/drive_c/RA2/wsock32.dll
```

If rendering is slow, reduce `RESOLUTION` to `800x600` in `.env`, update `ddraw.ini`, `RA2.ini`, and `RA2MD.ini` to match, then recreate the containers:

```bash
docker compose down
docker compose up -d
```
