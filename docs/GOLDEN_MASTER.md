# RA2 NAS Golden Master

This document is the master descriptor for the current known-good Red Alert 2 / Yuri's Revenge NAS streaming program. It captures the runtime state that stabilized gameplay after repeated `gamemd.exe` crashes and should be read before changing Wine, streaming, input, CPU affinity, compose overlays, or NAS paths.

## Golden-Master Summary

- Primary play path: ultra-light browser streaming, not noVNC, Selkies, Moonlight, or the legacy WebRTC overlay.
- Player URLs:
  - Player 1 LAN: `https://192.168.0.193:6081/`
  - Player 2 LAN: `https://192.168.0.193:6082/`
- NAS project root: `/volume2/Data/App_Development/ra2-lan-party`
- Active compose project: `/volume2/Data/App_Development/ra2-lan-party/project`
- Local mirror: `/Users/computer/Desktop/App Development/Red_Alert2_NAS:Arch/synology-ra2-arch`
- Runtime image: `ra2-lan-party:ultra`
- Active containers: `ra2-player-1`, `ra2-player-2`
- Stable Wine runtime: Wine amd64 package with a `win32` prefix, not WoW64.
- Critical stability invariant: each game instance must run on exactly one assigned CPU.

The single most important stability discovery is CPU affinity. Do not remove, weaken, or bypass game-process pinning unless a replacement is proven under live gameplay.

## Current Stable Architecture

The ultra profile removes heavyweight desktop and browser-remoting layers from the hot path. Each player container runs only the processes needed for RA2 and the custom browser stream:

- `Xvfb` provides a headless X display.
- `openbox` supplies the minimal window manager expected by Wine and the game.
- PulseAudio captures game audio.
- `ra2-stream-gateway.py` serves HTTPS and WSS on the same external player port.
- `stream-helper` captures Xvfb output and audio through GStreamer.
- Wine launches `RA2MD.exe`, which starts `gamemd.exe`.
- `start-game-ultra.sh` supervises the game process, collects diagnostics, and enforces CPU affinity.

Not part of the primary path:

- noVNC, `x11vnc`, and websockify
- Selkies/Webtop
- Moonlight/Sunshine/Wolf
- legacy WebRTC signaling/input/media ports
- full desktop environments such as XFCE or KDE

Those alternatives may remain as experiments or recovery paths, but the golden master is the ultra browser profile.

## Protocols And Ports

The browser play path uses one TCP port per player:

- `6081/tcp` -> player 1 HTTPS/WSS gateway
- `6082/tcp` -> player 2 HTTPS/WSS gateway

The root URL serves the play page. `/vnc.html` is not the ultra play URL.

Transport:

- Page: HTTPS from `ra2-stream-gateway.py`
- Video/audio/control channel: WSS, same origin and same port
- Video: H.264 by default, decoded by Chromium-family browser WebCodecs
- Audio: Opus low-latency at `64000` bps by default, with PCM as a fallback
- Input: browser events over WSS to `xdotool`
- One active WSS stream session per player container; a newer browser tab replaces the previous session

No WebRTC UDP media range is required for the golden path.

## Input Policy

Full gameplay input is required. Do not block useful inputs as a crash workaround.

Forwarded input includes:

- left, middle, right, and extra mouse buttons where the browser exposes them
- wheel up/down
- keyboard events
- Alt and Meta key events
- modifier combinations used by the game or by players

If input appears correlated with a crash, debug Wine/game/runtime state instead of adding broad input guards. Input blocking regresses gameplay and is not considered part of the stable solution.

## CPU Affinity

The game must be pinned to one CPU per player:

- Player 1: `RA2_GAME_CPUSET=0`
- Player 2: `RA2_GAME_CPUSET=1`
- Future players: default to `PLAYER_ID - 1` unless explicitly overridden.

The launcher is started through `taskset -c "$GAME_CPUSET"`, and the watchdog re-applies `taskset -pc "$GAME_CPUSET"` to live `gamemd.exe` processes. The second step matters because `gamemd.exe` can escape the launcher's affinity after Wine starts child processes.

The capture/encode helper is isolated onto separate cores through `ULTRA_STREAM_CPUSET` (default `2,3` on the 4-core J4125). The gateway launches the helper through `taskset -c "$ULTRA_STREAM_CPUSET"` so GStreamer capture/convert/encode never preempts a pinned game core. This complements, and never replaces, the game-side pin. Verified live: the helper affinity list is `2,3` while games keep cores `0` and `1`.

The expected live checks are:

```bash
docker exec ra2-player-1 sh -lc 'echo "$RA2_GAME_CPUSET"; pgrep -x gamemd.exe | xargs -r taskset -pc'
docker exec ra2-player-2 sh -lc 'echo "$RA2_GAME_CPUSET"; pgrep -x gamemd.exe | xargs -r taskset -pc'
```

Both the environment value and the process affinity must match the assigned CPU.

## Wine Runtime

The stable runtime currently uses:

- `WINE_VARIANT=amd64`
- `WINE_ARCH=win32`
- `WINE_ENABLE_MULTILIB=1`
- separate per-player `win32` prefixes

The 32-bit prefix was the key Wine-side stabilization. WoW64 and a 64-bit prefix were previously associated with repeated `gamemd.exe` crashes and resets. Do not switch back to a 64-bit prefix just because the host CPU is 64-bit.

RA2/Yuri's Revenge is a 32-bit Windows game. A 64-bit host package can still be useful for runtime packaging, but a 64-bit Wine prefix is not expected to make `gamemd.exe` execute as a 64-bit process. Any 64-bit optimization should be limited to host-side helper processes or container/library choices unless proven otherwise.

## Compatibility Settings

The prefix setup does not apply Windows 98 compatibility mode or any other Wine app-default Windows-version override for RA2 executables.

Observed stability evidence suggests CPU pinning plus the `win32` prefix are the important fixes. Win98 compatibility mode alone did not fix crashes and is not part of the golden master. Existing prefixes should have legacy `HKEY_CURRENT_USER\Software\Wine\AppDefaults\RA2*.exe` and `gamemd.exe` overrides removed during startup.

## Streaming Defaults

Current ultra defaults:

- Display: `RESOLUTION=1024x768` at `RA2_DISPLAY_DEPTH=16` (16 bpp is the validated golden value; do not change depth casually — the game and capture path were proven at 16)
- Stream size: follows the display (`native`); the transport menu can downscale per session to 960x720 / 800x600 / 640x480 on the GPU, with input coordinates mapped back onto the display
- Video codec: `H264` (default); H.265 8-bit and H.265 10-bit are selectable hardware options
- Hardware encode required: `ULTRA_VIDEO_REQUIRE_HW=1`
- HEVC options exposed: `ULTRA_H265_TEST_ENABLED=1`
- Frame rate: `24`
- Bitrate: `900000`
- Keyframe interval: `1` second
- Audio codec: `opus`
- Audio bitrate: `64000` by default; selectable higher Opus rates remain available for testing.
- Audio frame size: `10` ms
- Audio source rate: `44100`
- Audio transport rate: `48000`
- Encoder CPU isolation: `ULTRA_STREAM_CPUSET=2,3`
- GPU convert/scale: `ULTRA_VIDEO_GPU_SCALE=1` (vapostproc front before the VA encoder)
- TLS enabled: `ULTRA_GATEWAY_TLS=1`

The video pipeline uses a GPU front when `vapostproc` is available: cheap CPU RGB16->BGRx expand, then GPU color conversion/scaling/upload feeding zero-copy VA surfaces into the VA encoder (`vah264enc` or `vah265enc`). Measured on the J4125: pipeline-only CPU dropped from 20.5% to 12.3% of a core (~40%), and the production helper total (including base64/IO) dropped from ~23% to ~16%. `ULTRA_VIDEO_GPU_SCALE=0` reverts to the CPU convert pipeline at runtime without a rebuild, and upgrades keep the previous image tagged `ra2-lan-party:ultra-prev` as the rollback path.

H.265 hardware encode is verified on both players: the i965 driver exposes `VAProfileHEVCMain` and `VAProfileHEVCMain10` encode entrypoints, and `vah265enc` accepts NV12 (8-bit) and P010_10LE (10-bit, `main-10` profile) through the same GPU front at the same measured pipeline cost as H.264 (~14% of one core at 1024x768@24). The gateway maps the UI's `H265_10` choice to `ULTRA_VIDEO_CODEC=H265` + `ULTRA_VIDEO_BIT_DEPTH=10` for the helper. Browser decode strings: `hev1.1.6.L93.B0` (8-bit) and `hev1.2.4.L93.B0` (10-bit), with `hvc1` fallbacks; clients without 10-bit HEVC decode degrade to 8-bit HEVC, then H.264. H.264 remains the default codec until HEVC has longer gameplay stability coverage. Because the game renders at 16 bpp, 10-bit mainly reduces encoder banding today and becomes more meaningful at `RA2_DISPLAY_DEPTH=24` (unproven for gameplay; not golden).

Compare H.265 using lower target bitrates, not the same bitrate as H.264. The VA encoder is rate-controlled, so equal target bitrates produce similar bandwidth and may look visually identical on low-motion RA2 screens.

## Audio And Stream Sessions

The browser must play only the user-selected stream audio. There is no parallel local test tone, media-element tone, or second audio path in the ultra client.

- Default transport menu: `opus` encoder, `64000` bps, `44100` Hz source, `48000` Hz Opus transport
- The `Enable audio` button unlocks Web Audio for the selected stream; it does not inject generated tones
- Reconnect and transport changes clear queued WebAudio buffers and reset the Opus decoder
- Audio packets whose codec does not match the selected encoder are ignored

Each player container allows one active stream helper at a time. If a second browser connects to the same player, the gateway stops the previous helper and closes the older WebSocket. This prevents duplicate Opus playback when multiple tabs or stale sessions are open.

Expected live check:

```bash
docker exec ra2-player-1 sh -lc 'pgrep -cx stream-helper || true'
```

During normal play there should be `0` or `1` `stream-helper` process, never `2`.

## Diagnostics

Per-player logs are kept under:

```text
/volume2/Data/App_Development/ra2-lan-party/logs/player1
/volume2/Data/App_Development/ra2-lan-party/logs/player2
```

The launcher writes or collects:

- `wine-current.log`
- `wine-previous.log`
- `latest-crash.log`
- `last-lockup.txt`
- `crash-<timestamp>-<reason>.log`
- `input-events.log`
- gateway lifecycle logs
- `video-diagnostics.log` for `/dev/dri`, `vainfo`, GStreamer, QSV/MSDK, and VA encoder discovery
- recent process state, memory, disk, X window, and Wine status
- Wine minidump helper output when available

The crash signature seen before stabilization was:

- exception: `EXCEPTION_ACCESS_VIOLATION (c0000005)`
- process: `gamemd.exe`
- stable fault address: `0x007BC806`
- bad read pointer varied between crashes

Minidump capture can fail when the process is already dying. The text crash report and live process/affinity checks are often more reliable.

## Deployment Commands

Use the active NAS project directory:

```bash
cd /volume2/Data/App_Development/ra2-lan-party/project
RA2_COMPOSE_ULTRA=1 sh scripts/redeploy-ultra.sh
```

Equivalent compose stack:

```bash
docker compose --env-file .env -f compose.yaml -f compose.https.yaml -f compose.ultra.yaml up -d
```

Recreate both golden player containers:

```bash
docker compose --env-file .env -f compose.yaml -f compose.https.yaml -f compose.ultra.yaml up -d --no-build --force-recreate ra2-player-1 ra2-player-2
```

## Verification

Minimum verification after changes:

```bash
python3 -m pytest tests/test_project_contracts.py -q
RA2_COMPOSE_ULTRA=1 sh scripts/check-ultra-ready.sh
```

Live process verification on the NAS:

```bash
docker exec ra2-player-1 sh -lc 'echo RA2_GAME_CPUSET=$RA2_GAME_CPUSET; pgrep -x gamemd.exe | xargs -r taskset -pc'
docker exec ra2-player-2 sh -lc 'echo RA2_GAME_CPUSET=$RA2_GAME_CPUSET; pgrep -x gamemd.exe | xargs -r taskset -pc'
```

Manual gameplay verification should include:

- both players opening the root stream URLs
- mouse buttons and wheel
- keyboard input, including Alt/Meta paths that browsers expose
- several minutes of real gameplay without `gamemd.exe` crash/restart
- checking that player 2 remains pinned to CPU 1 after `gamemd.exe` appears

## Fine Tuning Guidance

Safe tuning areas:

- H.264 bitrate and quality presets
- selecting H.265 8-bit / 10-bit in the transport menu (hardware-verified; falls back to H.264 automatically)
- per-session stream resolution downscales (960x720 / 800x600 / 640x480)
- frame rate between low and balanced values
- Opus bitrate and frame size
- mouse move polling rate
- diagnostics verbosity

High-risk tuning areas:

- CPU affinity behavior
- Wine prefix architecture
- replacing `win32` prefix with WoW64 or `win64`
- adding input guards
- changing `RESOLUTION` or `RA2_DISPLAY_DEPTH` (restarts the game display; 1024x768x16 is the proven configuration)
- making H.265 the default codec before long gameplay coverage
- adding heavyweight desktop remoting processes back into the primary container

When optimizing, change one high-risk variable at a time and keep the golden-master rollback path intact.

## Current Cleanup Candidates

These are not part of the golden-master proof and may be simplified after the descriptor is saved:

- tighten minidump behavior if Wine attach timing can be improved
- prune obsolete experimental browser paths only after confirming they are not needed as fallbacks

Do not treat cleanup as permission to change the core stability invariant: `gamemd.exe` must stay pinned to a single assigned CPU.
