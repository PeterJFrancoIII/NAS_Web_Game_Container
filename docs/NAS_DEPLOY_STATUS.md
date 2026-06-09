# NAS Deploy Status

Last updated after live verification on `MediaServer2` (`192.168.0.193`).

## Working

- `ra2-player-1` and `ra2-player-2` run `Up (healthy)`
- noVNC returns HTTP `200` on ports `6081` and `6082`
- Kron4ek `wine-10.8` `amd64-wow64` initializes prefixes with both:
  - `drive_c/windows/system32/kernel32.dll`
  - `drive_c/windows/syswow64/kernel32.dll`
- RA2/Yuri launches (`RA2MD.exe` / `gamemd.exe -SPEEDCONTROL`)
- `/dev/dri/renderD128` is visible in containers with `RENDER_GID=937`
- FFmpeg registers `h264_vaapi` and `hevc_vaapi`

## Known limitation

Hardware encode smoke tests still fail on the DS225+ host kernel:

- `vainfo` only reports `VAProfileNone`
- `ffmpeg ... h264_vaapi` / `hevc_vaapi` fail with `No usable encoding profile found`
- Synology i915 debug reports `GuC disabled` and `HuC disabled`

This is a host DSM/i915 firmware exposure issue, not a missing container package. The project now removes `iHD_drv_video.so` and forces `LIBVA_DRIVER_NAME=i965` for Gemini Lake compatibility.

## Operator commands

One-shot rebuild and verification:

```bash
cd /volume2/Data/App_Development/ra2-lan-party/project
sudo sh scripts/admin-rebuild-check.sh
```

Verification only:

```bash
sudo sh scripts/verify-deployment.sh
```

Transcode probe only:

```bash
sudo sh scripts/check-transcode.sh ra2-player-1
```

## Browser URLs

```text
Player 1: http://192.168.0.193:6081/vnc.html
Player 2: http://192.168.0.193:6082/vnc.html
```
