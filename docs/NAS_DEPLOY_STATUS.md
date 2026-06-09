# NAS Deploy Status

Last updated after live verification on `MediaServer2` (`192.168.0.193`).

## Working

- `ra2-player-1` and `ra2-player-2` run `Up (healthy)`
- noVNC returns HTTPS `200` on ports `6081` and `6082`
- the browser Latency panel is injected into noVNC and uses the `latency` WebSocket token
- Kron4ek `wine-10.8` `amd64-wow64` initializes prefixes with both:
  - `drive_c/windows/system32/kernel32.dll`
  - `drive_c/windows/syswow64/kernel32.dll`
- RA2/Yuri launches (`RA2MD.exe` / `gamemd.exe -SPEEDCONTROL`)
- `/dev/dri/renderD128` is visible in containers with `RENDER_GID=937` (transcode overlay enabled by default)
- FFmpeg registers `h264_vaapi` and `hevc_vaapi`

## Hardware transcode (DS225+ host fix required)

Synology ships a stripped i915 stack (`enable_guc=0`, `VAProfileNone`). Container packages are ready (`iHD` removed, `LIBVA_DRIVER_NAME=i965`, transcode overlay on by default).

Enable host drivers once per boot cycle:

```bash
sudo sh scripts/enable-host-transcode.sh
```

After loading the community [Transcode_for_x25](https://github.com/007revad/Transcode_for_x25) modules:

- `vainfo` exposes H.264 and HEVC **EncSlice** profiles
- `h264_vaapi` and `hevc_vaapi` smoke tests pass
- `h264_qsv` may still fail; VA-API is the supported path on J4125 with `i965`

**Important:** schedule `transcode_for_x25.sh` or install the Transcode_for_x25 package at boot so the fix survives DSM reboots.

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
Player 1: https://192.168.0.193:6081/vnc.html
Player 2: https://192.168.0.193:6082/vnc.html
```
