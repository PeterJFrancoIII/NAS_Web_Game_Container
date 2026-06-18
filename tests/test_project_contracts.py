import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]


def read(relative_path):
    return (PROJECT_ROOT / relative_path).read_text(encoding="utf-8")


def env_values():
    values = {}
    for line in read(".env.example").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, value = line.split("=", 1)
        values[key] = value
    return values


class SynologyEnvironmentContractTest(unittest.TestCase):
    def test_env_defaults_use_app_development_project_layout(self):
        values = env_values()

        self.assertEqual(values["PROJECT_ROOT"], "/volume2/Data/App_Development/ra2-lan-party")
        self.assertEqual(values["ASSETS_DIR"], "/volume2/Data/App_Development/ra2-lan-party/assets")
        self.assertEqual(values["PREFIX1_DIR"], "/volume2/Data/App_Development/ra2-lan-party/prefixes/player1-win32")
        self.assertEqual(values["PREFIX2_DIR"], "/volume2/Data/App_Development/ra2-lan-party/prefixes/player2-win32")
        self.assertEqual(values["LOGS_DIR"], "/volume2/Data/App_Development/ra2-lan-party/logs")
        self.assertEqual(values["WINE_VARIANT"], "amd64")
        self.assertEqual(values["WINE_ARCH"], "win32")
        self.assertEqual(values["WINE_ENABLE_MULTILIB"], "1")

    def test_project_specific_nas_paths_stay_inside_ra2_project_root(self):
        forbidden_parent = "/" + "Data" + "/" + "App_Development"
        allowed_root = forbidden_parent + "/ra2-lan-party"
        skipped_dirs = {".git", ".pytest_cache", ".test-tmp", "__pycache__"}
        skipped_files = {Path(".cursor/rules/project-storage-boundary.mdc")}
        offenders = []

        for path in PROJECT_ROOT.rglob("*"):
            relative = path.relative_to(PROJECT_ROOT)
            if any(part in skipped_dirs for part in relative.parts):
                continue
            if relative in skipped_files or not path.is_file():
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            for line_number, line in enumerate(text.splitlines(), start=1):
                if forbidden_parent in line and allowed_root not in line:
                    offenders.append(f"{relative}:{line_number}: {line.strip()}")

        self.assertEqual([], offenders)

    def test_env_defaults_define_two_browser_clients_and_unique_player_identity(self):
        values = env_values()

        self.assertEqual(values["PLAYER1_HTTP_PORT"], "6081")
        self.assertEqual(values["PLAYER2_HTTP_PORT"], "6082")
        self.assertEqual(values["PLAYER1_WEBRTC_SIGNAL_PORT"], "6083")
        self.assertEqual(values["PLAYER2_WEBRTC_SIGNAL_PORT"], "6084")
        self.assertEqual(values["PLAYER1_WEBRTC_INPUT_PORT"], "6085")
        self.assertEqual(values["PLAYER2_WEBRTC_INPUT_PORT"], "6086")
        self.assertEqual(values["PLAYER1_WEBRTC_UDP_MIN"], "62001")
        self.assertEqual(values["PLAYER2_WEBRTC_UDP_MAX"], "62040")
        self.assertEqual(values["PLAYER1_WEBRTC_VIDEO_UDP_MIN"], "62001")
        self.assertEqual(values["PLAYER1_WEBRTC_VIDEO_UDP_MAX"], "62010")
        self.assertEqual(values["PLAYER1_WEBRTC_AUDIO_UDP_MIN"], "62011")
        self.assertEqual(values["PLAYER1_WEBRTC_AUDIO_UDP_MAX"], "62020")
        self.assertEqual(values["PLAYER2_WEBRTC_VIDEO_UDP_MIN"], "62021")
        self.assertEqual(values["PLAYER2_WEBRTC_VIDEO_UDP_MAX"], "62030")
        self.assertEqual(values["PLAYER2_WEBRTC_AUDIO_UDP_MIN"], "62031")
        self.assertEqual(values["PLAYER2_WEBRTC_AUDIO_UDP_MAX"], "62040")
        self.assertEqual(values["WEBRTC_LATENCY_PRESET"], "stable")
        self.assertEqual(values["WEBRTC_VIDEO_CODEC"], "H264")
        self.assertEqual(values["WEBRTC_VIDEO_REQUIRE_HW"], "1")
        self.assertEqual(values["WEBRTC_VIDEO_WIDTH"], "1024")
        self.assertEqual(values["WEBRTC_VIDEO_HEIGHT"], "768")
        self.assertEqual(values["WEBRTC_VIDEO_FPS"], "20")
        self.assertEqual(values["WEBRTC_VIDEO_BITRATE"], "800000")
        self.assertEqual(values["WEBRTC_VIDEO_RTP_MTU"], "700")
        self.assertEqual(values["WEBRTC_OFFER_WAIT_SECONDS"], "30")
        self.assertEqual(values["WEBRTC_ICE_TCP"], "1")
        self.assertEqual(values["WEBRTC_ICE_UDP"], "0")
        self.assertEqual(values["WEBRTC_AUDIO_BITRATE"], "96000")
        self.assertEqual(values["WEBRTC_AUDIO_RATE"], "44100")
        self.assertEqual(values["NAS_LAN_IP"], "192.168.0.193")
        self.assertEqual(values["NAS_PUBLIC_HOSTNAME"], "peterjfrancoiii2.synology.me")
        self.assertIn("/ra2-lan-party/tls", values["TLS_DIR"])
        self.assertEqual(values["DRI_DEVICE"], "/dev/dri")
        self.assertEqual(values["RENDER_GID"], "937")
        self.assertEqual(values["LIBVA_DRIVER_NAME"], "i965")
        self.assertEqual(values["RA2_MEMORY_PROFILE"], "two-player-low")
        self.assertEqual(values["RA2_MEM_LIMIT"], "512m")
        self.assertEqual(values["RA2_SHM_SIZE"], "256m")
        self.assertEqual(values["RA2_ENABLE_AUDIO_PROXY"], "0")
        self.assertEqual(values["RA2_ENABLE_LATENCY_PROXY"], "0")
        self.assertEqual(values["AUDIO_QUEUE_BUFFERS"], "4")
        self.assertEqual(values["AUDIO_WEBM_CLUSTER_MS"], "150")
        self.assertEqual(values["RA2_RESTART_POLICY"], "no")
        self.assertEqual(values["RA2_PIDS_LIMIT"], "256")
        self.assertEqual(values["RA2_COMPOSE_TRANSCODE"], "0")
        self.assertNotEqual(values["PLAYER1_SERIAL"], values["PLAYER2_SERIAL"])
        self.assertIn("VNC_PASSWORD", values)
        self.assertEqual(values["GAME_EXE"], "RA2MD.exe")


class ComposeTopologyContractTest(unittest.TestCase):
    def test_compose_renders_with_example_environment(self):
        if not shutil.which("docker"):
            self.skipTest("docker CLI is not installed")

        result = subprocess.run(
            [
                "docker",
                "compose",
                "--env-file",
                str(PROJECT_ROOT / ".env.example"),
                "-f",
                str(PROJECT_ROOT / "compose.yaml"),
                "config",
                "--quiet",
            ],
            cwd=PROJECT_ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_compose_defines_two_static_game_instances_on_private_bridge(self):
        compose = read("compose.yaml")

        self.assertIn("image: ra2-lan-party:latest", compose)
        self.assertIn("ra2-player-1:", compose)
        self.assertIn("ra2-player-2:", compose)
        self.assertIn("x-ra2-player-env", compose)
        player1_net = read("compose.player1-network.yaml")
        player2_net = read("compose.player2-network.yaml")
        self.assertIn("ipv4_address: 172.22.20.11", player1_net)
        self.assertIn("ipv4_address: 172.22.20.12", player2_net)
        self.assertIn("subnet: 172.22.20.0/24", compose)
        self.assertIn("gateway: 172.22.20.1", compose)
        self.assertIn("driver: bridge", compose)
        self.assertIn('restart: "${RA2_RESTART_POLICY:-no}"', compose)
        self.assertNotIn("cpus:", compose)
        self.assertIn("pids_limit: ${RA2_PIDS_LIMIT:-256}", compose)
        self.assertIn('mem_limit: "${RA2_MEM_LIMIT:-512m}"', compose)
        self.assertIn('shm_size: "${RA2_SHM_SIZE:-256m}"', compose)
        self.assertNotIn("PLAYER1_MEM_LIMIT", compose)
        self.assertNotIn("PLAYER2_MEM_LIMIT", compose)
        self.assertIn("RA2_MEMORY_PROFILE", compose)
        self.assertIn("RA2_ENABLE_AUDIO_PROXY", compose)

    def test_compose_exposes_browser_display_ports_without_exposing_vnc_directly(self):
        compose = read("compose.yaml")

        self.assertIn('"${PLAYER1_HTTP_PORT:-6081}:6080/tcp"', compose)
        self.assertIn('"${PLAYER2_HTTP_PORT:-6082}:6080/tcp"', compose)
        self.assertNotIn(":5900", compose)

    def test_compose_requires_runtime_secrets_from_env(self):
        compose = read("compose.yaml")

        self.assertIn("${PLAYER1_SERIAL:?set PLAYER1_SERIAL in .env}", compose)
        self.assertIn("${PLAYER2_SERIAL:?set PLAYER2_SERIAL in .env}", compose)
        self.assertIn("${VNC_PASSWORD:?set VNC_PASSWORD in .env}", compose)
        self.assertNotIn("PLAYER1_VNC_PASSWORD", compose)
        self.assertNotIn("PLAYER2_VNC_PASSWORD", compose)

    def test_compose_mounts_shared_assets_read_only_and_prefixes_read_write(self):
        compose = read("compose.yaml")

        self.assertIn("/home/commander/game_assets:ro", compose)
        self.assertIn("/prefixes/player1-win32}:/home/commander/.wine:rw", compose)
        self.assertIn("/prefixes/player2-win32}:/home/commander/.wine:rw", compose)
        self.assertNotIn("/home/commander/.wine/drive_c/RA2:ro", compose)
        self.assertNotIn("/rmcache:/home/commander/.wine/drive_c/RA2/rmcache:rw", compose)
        self.assertIn("./container/entrypoint.sh:/opt/ra2/entrypoint.sh:ro", compose)
        self.assertIn("./container/patch-novnc.sh:/opt/ra2/patch-novnc.sh:ro", compose)
        self.assertIn("./container/audio-proxy.sh:/opt/ra2/audio-proxy.sh:ro", compose)
        self.assertIn("./container/latency-proxy.sh:/opt/ra2/latency-proxy.sh:ro", compose)
        self.assertIn("./container/latency-overlay.js:/opt/ra2/latency-overlay.js:ro", compose)
        self.assertIn("./container/cursor-lock.js:/opt/ra2/cursor-lock.js:ro", compose)
        self.assertIn("./container/asound.conf:/etc/asound.conf:ro", compose)

    def test_transcode_overlay_grants_gpu_access_without_changing_default_stack(self):
        compose = read("compose.yaml")
        overlay = read("compose.transcode.yaml")

        self.assertNotIn("/dev/dri", compose)
        self.assertIn("${DRI_DEVICE:-/dev/dri}:/dev/dri", overlay)
        self.assertIn("${RENDER_GID:-937}", overlay)
        self.assertIn("${VIDEO_GID:-44}", overlay)
        self.assertIn("LIBVA_DRIVER_NAME: ${LIBVA_DRIVER_NAME:-i965}", overlay)

    def test_https_overlay_mounts_tls_without_changing_default_stack(self):
        compose = read("compose.yaml")
        overlay = read("compose.https.yaml")

        self.assertNotIn("/opt/ra2/tls", compose)
        self.assertIn("${TLS_DIR:-/volume2/Data/App_Development/ra2-lan-party/tls}:/opt/ra2/tls:ro", overlay)
        self.assertIn("TLS_CERT: /opt/ra2/tls/cert.pem", overlay)
        self.assertIn("TLS_KEY: /opt/ra2/tls/key.pem", overlay)

    def test_webrtc_overlay_adds_udp_and_signaling_ports_without_changing_default_stack(self):
        compose = read("compose.yaml")
        overlay = read("compose.webrtc.yaml")

        self.assertNotIn("WEBRTC_ENABLED", compose)
        self.assertNotIn("compose.webrtc.yaml", compose)
        self.assertIn("WEBRTC_ENABLED: \"1\"", overlay)
        self.assertIn("${DRI_DEVICE:-/dev/dri}:/dev/dri", overlay)
        self.assertIn("${RENDER_GID:-937}", overlay)
        self.assertIn("LIBVA_DRIVER_NAME: ${LIBVA_DRIVER_NAME:-i965}", overlay)
        self.assertIn("${PLAYER1_WEBRTC_SIGNAL_PORT:-6083}:6090/tcp", overlay)
        self.assertIn("${PLAYER2_WEBRTC_SIGNAL_PORT:-6084}:6090/tcp", overlay)
        self.assertIn("${PLAYER1_WEBRTC_INPUT_PORT:-6085}:5731/tcp", overlay)
        self.assertIn("${PLAYER2_WEBRTC_INPUT_PORT:-6086}:5731/tcp", overlay)
        self.assertIn("WEBRTC_VIDEO_UDP_PORT_MIN: ${PLAYER1_WEBRTC_VIDEO_UDP_MIN:-62001}", overlay)
        self.assertIn("WEBRTC_AUDIO_UDP_PORT_MIN: ${PLAYER1_WEBRTC_AUDIO_UDP_MIN:-62011}", overlay)
        self.assertIn("WEBRTC_VIDEO_UDP_PORT_MIN: ${PLAYER2_WEBRTC_VIDEO_UDP_MIN:-62021}", overlay)
        self.assertIn("WEBRTC_AUDIO_UDP_PORT_MIN: ${PLAYER2_WEBRTC_AUDIO_UDP_MIN:-62031}", overlay)
        self.assertIn("/udp", overlay)
        self.assertIn("./container/webrtc-media.py:/opt/ra2/webrtc-media.py:ro", overlay)

    def test_compose_webrtc_overlay_renders_with_example_environment(self):
        if not shutil.which("docker"):
            self.skipTest("docker CLI is not installed")

        result = subprocess.run(
            [
                "docker",
                "compose",
                "--env-file",
                str(PROJECT_ROOT / ".env.example"),
                "-f",
                str(PROJECT_ROOT / "compose.yaml"),
                "-f",
                str(PROJECT_ROOT / "compose.webrtc.yaml"),
                "config",
                "--quiet",
            ],
            cwd=PROJECT_ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_compose_https_overlay_renders_with_example_environment(self):
        if not shutil.which("docker"):
            self.skipTest("docker CLI is not installed")

        result = subprocess.run(
            [
                "docker",
                "compose",
                "--env-file",
                str(PROJECT_ROOT / ".env.example"),
                "-f",
                str(PROJECT_ROOT / "compose.yaml"),
                "-f",
                str(PROJECT_ROOT / "compose.https.yaml"),
                "config",
                "--quiet",
            ],
            cwd=PROJECT_ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)


class RuntimeImageContractTest(unittest.TestCase):
    def test_dockerfile_uses_arch_linux_wine_display_stack_and_non_root_user(self):
        dockerfile = read("container/Dockerfile")

        self.assertIn("FROM archlinux:latest", dockerfile)
        self.assertIn("NOVNC_REF=v1.5.0", dockerfile)
        self.assertIn("WEBSOCKIFY_REF=v0.12.0", dockerfile)
        self.assertIn("WINE_BUILD=10.8", dockerfile)
        self.assertIn("WINE_VARIANT=amd64-wow64", dockerfile)
        self.assertIn("wine-${WINE_BUILD}-${WINE_VARIANT}.tar.xz", dockerfile)
        self.assertIn("/opt/wine/bin", dockerfile)
        for package in [
            "ffmpeg",
            "gstreamer",
            "gst-plugins-base",
            "gst-plugins-good",
            "gst-plugins-bad",
            "gst-plugins-ugly",
            "gst-libav",
            "gst-plugin-va",
            "libva",
            "libva-intel-driver",
            "libva-utils",
            "vpl-gpu-rt",
            "libmfx",
            "pulseaudio",
            "pulseaudio-alsa",
            "socat",
            "xorg-server-xvfb",
            "openbox",
            "x11vnc",
            "supervisor",
            "mesa",
            "python",
        ]:
            self.assertIn(package, dockerfile)
        self.assertIn("patch-novnc.sh", dockerfile)
        self.assertIn("audio-proxy.sh", dockerfile)
        self.assertIn("start-websockify.sh", dockerfile)
        self.assertIn("healthcheck-novnc.sh", dockerfile)
        self.assertIn("LIBVA_DRIVER_NAME=i965", dockerfile)
        self.assertIn("rm -f /usr/lib/dri/iHD_drv_video.so", dockerfile)
        self.assertNotIn("intel-media-driver", dockerfile)
        self.assertIn("GST_VAAPI_ALL_DRIVERS=1", dockerfile)
        self.assertIn("useradd -m -u 1000 -s /bin/bash commander", dockerfile)
        self.assertIn("COPY container/asound.conf /etc/asound.conf", dockerfile)
        self.assertIn("COPY container/cursor-lock.js /opt/ra2/cursor-lock.js", dockerfile)
        self.assertIn("webrtc-media.py", dockerfile)
        self.assertIn("input-proxy.py", dockerfile)
        self.assertIn("python-websockets", dockerfile)
        self.assertIn("xdotool", dockerfile)
        self.assertIn("USER commander", dockerfile)

    def test_asound_routes_alsa_output_to_pulseaudio(self):
        asound = read("container/asound.conf")

        self.assertIn("type pulse", asound)
        self.assertNotIn("type null", asound)

    def test_browser_audio_defaults_to_44100_hz_capture(self):
        pulse = read("container/pulse/default.pa")
        proxy = read("container/audio-proxy.sh")
        novnc_patch = read("container/patch-novnc.sh")
        pulse_launcher = read("container/start-pulseaudio.sh")

        self.assertIn("rate=", pulse)
        self.assertIn("PULSE_SAMPLE_RATE='44100'", proxy)
        self.assertIn('proxy_cmd="/bin/sh ${SCRIPT} proxy', proxy)
        self.assertIn("}, '44100', 'Audio sample rate", novnc_patch)
        self.assertIn("audio_encrypt", novnc_patch)
        self.assertIn("AUDIO_BUFFER_MIN_REMAIN", novnc_patch)
        self.assertIn("AUDIO_DRIFT_CHECK_INTERVAL_MS", novnc_patch)
        self.assertIn("AUDIO_DRIFT_MAX_TOLERANCE", novnc_patch)
        self.assertIn("latency-overlay.js", novnc_patch)
        self.assertIn("cursor-lock.js", novnc_patch)
        self.assertIn("DRIFT_CHECK_INTERVAL > 0", novnc_patch)
        self.assertIn("AUDIO_TARGET_LATENCY", novnc_patch)
        self.assertIn("AUDIO_MAX_PLAYBACK_RATE_DELTA", novnc_patch)
        self.assertIn("UI.initSetting('compression', 0)", novnc_patch)
        self.assertIn("targetLatency", novnc_patch)
        self.assertIn("playbackRate = 1 + correction", novnc_patch)
        self.assertIn("AUDIO_PLUGIN_REFRESH", novnc_patch)
        self.assertIn("window.location.protocol === 'https:'", novnc_patch)
        self.assertIn("AUDIO_WEBM_CLUSTER_MS", proxy)
        self.assertIn("AUDIO_OPUS_FRAME_MS", proxy)
        self.assertIn("AUDIO_QUEUE_BUFFERS", proxy)
        self.assertIn("sync-audio-transport.sh", pulse_launcher)
        self.assertIn('PA_FILE="/opt/ra2/pulse/default.pa"', pulse_launcher)
        self.assertIn('PA_FILE="${ULTRA_PULSE_PA:-/home/commander/.ra2/pulse.pa}"', pulse_launcher)
        self.assertIn("mkdir -p /tmp/pulse", pulse_launcher)
        self.assertNotIn("--script=", pulse_launcher)
        self.assertIn("Opus uses 48 kHz natively", read("container/ra2-stream-gateway.py"))
        ultra_js = read("container/remote-ultra/ultra-play.js")
        self.assertIn("resolveOpusAudioQuality", ultra_js)
        self.assertIn("stopScheduledAudioSources", ultra_js)
        self.assertIn("OPUS_NATIVE_RATE", ultra_js)
        helper = read("container/stream-helper.c")
        self.assertIn("OPUS_NATIVE_RATE 48000", helper)
        self.assertIn("audioresample", helper)
        sync_audio = read("container/sync-audio-transport.sh")
        self.assertIn("rate=${NATIVE_RATE}", sync_audio)

    def test_browser_cursor_lock_supports_fullscreen_toggle_and_release_shortcut(self):
        cursor_lock = read("container/cursor-lock.js")

        self.assertIn("requestPointerLock", cursor_lock)
        self.assertIn("requestFullscreen", cursor_lock)
        self.assertIn("exitPointerLock", cursor_lock)
        self.assertIn("Ctrl+Alt+L", cursor_lock)
        self.assertIn('event.code === "KeyL"', cursor_lock)
        self.assertIn("movementX", cursor_lock)
        self.assertIn("dispatchSyntheticEvent", cursor_lock)

    def test_webrtc_remote_play_uses_xvfb_pulse_and_wss_signaling(self):
        helper = read("container/webrtc-media-helper.c")
        webrtc = read("container/webrtc-media.py")
        input_proxy = read("container/input-proxy.py")
        remote_js = read("container/remote/remote-play.js")

        self.assertIn("ximagesrc", helper)
        self.assertIn("tcpclientsrc", helper)
        self.assertIn("webrtcbin", helper)
        self.assertIn("WEBRTC_UDP_PORT_MIN", helper)
        self.assertIn("name=sendrecv", helper)
        self.assertIn("WEBRTC_VIDEO_CODEC", helper)
        self.assertIn("WEBRTC_VIDEO_REQUIRE_HW", helper)
        self.assertIn("vah264enc", helper)
        self.assertIn("vah265enc", helper)
        self.assertIn("WEBRTC_VIDEO_BIT_DEPTH", helper)
        self.assertIn("P010_10LE", helper)
        self.assertIn("video/x-h265", helper)
        self.assertIn("rtph264pay", helper)
        self.assertIn("rtph265pay", helper)
        self.assertIn("profile-id=1", helper)
        self.assertIn("encoding-name=%s", helper)
        self.assertIn("rawaudioparse", helper)
        self.assertIn("latency=0", helper)
        self.assertIn("leaky=downstream", helper)
        self.assertIn("WEBRTC_MEDIA_HELPER", webrtc)
        self.assertIn("offer_event", webrtc)
        self.assertIn("xdotool", input_proxy)
        self.assertIn("WEBRTC_INPUT_BACKEND", input_proxy)
        self.assertIn("uinput_backend", input_proxy)
        self.assertIn("RTCPeerConnection", remote_js)
        self.assertIn("WebSocket", remote_js)
        self.assertIn("warnIfHevcUnsupported", remote_js)
        self.assertIn("transport=", remote_js)
        self.assertIn("browserSupportsHevc", remote_js)
        self.assertIn("playoutDelayHint", remote_js)
        self.assertIn("remoteVideo", remote_js)

    def test_webrtc_bridge_single_client_and_stale_helper_cleanup(self):
        webrtc = read("container/webrtc-media.py")

        self.assertIn("_stop_stale_helper_children", webrtc)
        self.assertIn("pkill", webrtc)
        self.assertIn("rejecting extra client", webrtc)
        self.assertIn("another client is already connected", webrtc)
        self.assertIn("stopping helper pid=", webrtc)
        self.assertIn("helper started pid=", webrtc)
        self.assertIn("offer ready in", webrtc)
        self.assertIn("signaling_idle", webrtc)
        self.assertNotIn("self.clients.clear()", webrtc)

    def test_webrtc_latency_preset_and_stable_baseline(self):
        start = read("container/start-webrtc.sh")
        compose = read("compose.webrtc.yaml")
        env_example = read(".env.example")

        self.assertIn("WEBRTC_LATENCY_PRESET", start)
        self.assertIn("WEBRTC_RUNTIME_CODEC_FILE", start)
        self.assertIn("WEBRTC_VIDEO_BIT_DEPTH", start)
        self.assertIn("stable)", start)
        self.assertIn("low)", start)
        self.assertNotIn("experimental)", start)
        self.assertIn("ULTRA_DISPLAY_ENV", start)
        self.assertIn("DISPLAY_W", start)
        self.assertIn('WEBRTC_VIDEO_WIDTH:-$DISPLAY_W', start)
        self.assertIn("WEBRTC_VIDEO_FPS:-24", start)
        self.assertIn("WEBRTC_VIDEO_BITRATE:-1000000", start)
        self.assertIn("WEBRTC_LATENCY_PRESET", compose)
        self.assertIn("WEBRTC_VIDEO_WIDTH:-1024", compose)
        self.assertIn("WEBRTC_LATENCY_PRESET=stable", env_example)
        self.assertIn("WEBRTC_VIDEO_CODEC=H264", env_example)
        self.assertIn("WEBRTC_VIDEO_FPS=20", env_example)
        self.assertIn("WEBRTC_VIDEO_BITRATE=800000", env_example)
        self.assertIn("WEBRTC_VIDEO_REQUIRE_HW=1", env_example)
        self.assertIn("WEBRTC_VIDEO_RTP_MTU=700", env_example)
        self.assertIn("WEBRTC_ICE_UDP=0", env_example)
        self.assertIn("RA2_COMPOSE_WEBRTC_UDP=0", env_example)
        self.assertIn("WEBRTC_INPUT_BACKEND=xdotool", env_example)
        self.assertIn("UINPUT_DEVICE=/dev/uinput", env_example)

    def test_remote_play_input_rate_limit_and_runtime_stats(self):
        remote_js = read("container/remote/remote-play.js")
        input_proxy = read("container/input-proxy.py")

        self.assertIn("INPUT_MOVE_HZ", remote_js)
        self.assertIn("reportRuntimeStats", remote_js)
        self.assertIn("frameStalls", remote_js)
        self.assertIn("requestVideoFrameCallback", remote_js)
        self.assertIn("paintStalls", remote_js)
        self.assertIn("video frame stalled", remote_js)
        self.assertIn("scheduleAutoMediaReconnect", remote_js)
        self.assertIn("connected with RTP bytes but no decoded dimensions", remote_js)
        self.assertIn("async function reconnect", remote_js)
        self.assertEqual(remote_js.count("await createPeerConnection();"), 1)
        self.assertIn("WEBRTC_INPUT_MOVE_HZ", input_proxy)
        self.assertIn("move_dropped", input_proxy)

    def test_webrtc_redeploy_and_host_check_scripts_exist(self):
        redeploy = read("scripts/redeploy-webrtc.sh")
        host_check = read("scripts/check-low-latency-host.sh")
        sync = read("scripts/sync-to-nas.sh")
        safe_repair = read("scripts/safe-repair-launch.sh")

        self.assertIn("redeploy-webrtc", redeploy)
        self.assertIn("force-recreate", redeploy)
        self.assertIn("--no-build", redeploy)
        self.assertIn("H264/90000", redeploy)
        self.assertIn("VP8/90000", redeploy)
        self.assertIn("RA2_WEBRTC_BUILD", redeploy)
        self.assertIn("webrtc-media-helper", host_check)
        self.assertIn("/dev/dri", host_check)
        self.assertIn("sync-to-ram.sh", sync)
        self.assertIn("RA2_COMPOSE_WEBRTC_UDP=1", read("scripts/redeploy-webrtc-udp.sh"))
        self.assertIn("compare-selkies-webrtc.sh", read("docs/SELKIES_EXPERIMENT.md"))
        self.assertIn("RA2_SAFE_BUILD", safe_repair)
        self.assertIn("--no-build --force-recreate", safe_repair)
        self.assertIn("RA2_SAFE_WEBRTC", safe_repair)

    def test_two_player_memory_profile_and_optional_services(self):
        compose = read("compose.yaml")
        env_example = read(".env.example")
        start_webrtc = read("container/start-webrtc.sh")
        websockify = read("container/start-websockify.sh")
        audio_proxy = read("container/audio-proxy.sh")
        latency_proxy = read("container/latency-proxy.sh")
        x11vnc = read("container/start-x11vnc.sh")
        host_check = read("scripts/check-low-latency-host.sh")
        redeploy = read("scripts/redeploy-low-memory.sh")

        self.assertIn("two-player-low", env_example)
        self.assertIn("RA2_MEM_LIMIT=512m", env_example)
        self.assertIn("RA2_ENABLE_AUDIO_PROXY=0", env_example)
        self.assertIn("two-player-low", start_webrtc)
        self.assertIn("WEBRTC_VIDEO_FPS:-20", start_webrtc)
        self.assertIn("WEBRTC_VIDEO_BITRATE:-800000", start_webrtc)
        self.assertIn("RA2_ENABLE_NOVNC_FALLBACK", websockify)
        self.assertIn("RA2_ENABLE_AUDIO_PROXY", audio_proxy)
        self.assertIn("RA2_ENABLE_LATENCY_PROXY", latency_proxy)
        self.assertIn("RA2_ENABLE_NOVNC_FALLBACK", x11vnc)
        self.assertIn("docker stats --no-stream", host_check)
        self.assertIn("zombie/defunct", host_check)
        self.assertIn("$3 ~ /^Z/", host_check)
        self.assertIn("RA2_MEMORY_STRICT", host_check)
        self.assertIn("ra2-player-2", redeploy)
        self.assertIn("RA2_LOW_MEMORY_BUILD", redeploy)
        self.assertIn("--no-build --force-recreate", redeploy)
        self.assertIn("VP8/90000", redeploy)
        self.assertIn("/opt/ra2/webrtc-media-helper", redeploy)

    def test_webrtc_udp_overlay_enables_udp_ice(self):
        overlay = read("compose.webrtc-udp.yaml")
        lib = read("scripts/lib.sh")

        self.assertIn("WEBRTC_ICE_UDP: \"1\"", overlay)
        self.assertIn("WEBRTC_ICE_TCP: \"1\"", overlay)
        self.assertIn("webrtc_udp_overlay_enabled", lib)
        self.assertIn("compose.webrtc-udp.yaml", lib)

    def test_selkies_experiment_compose_is_side_by_side(self):
        compose = read("compose.selkies-experiment.yaml")
        docs = read("docs/SELKIES_EXPERIMENT.md")

        self.assertIn("ra2-selkies-experiment", compose)
        self.assertIn("linuxserver/webtop", compose)
        self.assertIn("container_name: ra2-selkies-experiment", compose)
        self.assertNotIn("\n  ra2-player-1:\n", compose)
        self.assertIn("does not affect", docs.lower())

    def test_moonlight_experiment_compose_files_are_side_by_side(self):
        sunshine = read("compose.sunshine.yaml")
        wolf = read("compose.wolf.yaml")
        tailscale = read("compose.tailscale.yaml")
        docs = read("docs/MOONLIGHT_EXPERIMENT.md")

        self.assertIn("ra2-sunshine-experiment", sunshine)
        self.assertIn("linuxserver/sunshine", sunshine)
        self.assertIn("network_mode: host", sunshine)
        self.assertNotIn("\n  ra2-player-1:\n", sunshine)

        self.assertIn("ra2-wolf-experiment", wolf)
        self.assertIn("games-on-whales/wolf", wolf)
        self.assertIn("/var/run/docker.sock", wolf)
        self.assertIn("device_cgroup_rules", wolf)
        self.assertIn("/run/udev", wolf)
        self.assertNotIn("\n  ra2-player-1:\n", wolf)

        self.assertIn("ra2-tailscale", tailscale)
        self.assertIn("tailscale/tailscale", tailscale)
        self.assertIn("TAILSCALE_AUTHKEY", tailscale)

        self.assertIn("archived", docs.lower())
        self.assertIn("check-moonlight-ready.sh", docs)
        self.assertIn("compare-moonlight-webrtc.sh", docs)

    def test_moonlight_and_tailscale_overlays_in_lib_sh(self):
        lib = read("scripts/lib.sh")
        env = read(".env.example")

        self.assertIn("moonlight_sunshine_overlay_enabled", lib)
        self.assertIn("moonlight_wolf_overlay_enabled", lib)
        self.assertIn("tailscale_overlay_enabled", lib)
        self.assertIn("compose.sunshine.yaml", lib)
        self.assertIn("compose.wolf.yaml", lib)
        self.assertIn("compose.tailscale.yaml", lib)
        self.assertIn("RA2_COMPOSE_MOONLIGHT=0", env)
        self.assertIn("RA2_COMPOSE_WOLF=0", env)
        self.assertIn("RA2_COMPOSE_TAILSCALE=0", env)
        self.assertIn("RA2_COMPOSE_SELKIES=0", env)
        self.assertIn("selkies_overlay_enabled", lib)
        self.assertIn("ultra_overlay_enabled", lib)
        self.assertIn("compose.ultra.yaml", lib)
        self.assertIn("RA2_COMPOSE_ULTRA=1", env)
        self.assertIn("RA2_PRODUCTION_RAM_MIB=6144", env)

    def test_consolidated_architecture_docs_and_boot_scripts(self):
        arch = read("docs/CONSOLIDATED_ARCHITECTURE.md")
        boot = read("scripts/dsm-boot-task.sh")
        uinput = read("scripts/enable-uinput.sh")
        selkies_deploy = read("scripts/redeploy-profile-selkies.sh")

        self.assertIn("0 — Browser (production)", arch)
        self.assertIn("Ultra Arch", arch)
        self.assertIn("redeploy-ultra.sh", arch)
        self.assertIn("GOLDEN_MASTER.md", arch)
        self.assertIn("modprobe uinput", boot)
        self.assertIn("videodriver", boot)
        self.assertIn("modprobe uinput", uinput)
        self.assertIn("RA2_COMPOSE_SELKIES=1", selkies_deploy)

    def test_webrtc_ice_reachability_and_host_prereq_scripts_exist(self):
        ice = read("scripts/check-webrtc-ice-reachability.sh")
        prereq = read("scripts/check-host-prerequisites.sh")
        moonlight = read("scripts/check-moonlight-ready.sh")
        tailscale = read("scripts/check-tailscale-direct.sh")

        self.assertIn("WEBRTC_ICE_CANDIDATE_HOST", ice)
        self.assertIn("62001-62040", ice)
        self.assertIn("check-transcode.sh", prereq)
        self.assertIn("6144", prereq)
        self.assertIn("ra2-sunshine-experiment", moonlight)
        self.assertIn("ra2-wolf-experiment", moonlight)
        self.assertIn("via DERP", tailscale)
        self.assertIn("41641", read("docs/TAILSCALE.md"))

    def test_remote_play_reports_actionable_ice_failures(self):
        remote_js = read("container/remote/remote-play.js")
        remote_html = read("container/remote/remote.html")
        media_py = read("container/webrtc-media.py")
        helper_c = read("container/webrtc-media-helper.c")

        self.assertIn("buildIceFailureHint", remote_js)
        self.assertIn("showIceFailureOverlay", remote_js)
        self.assertIn("noteRemoteCandidate", remote_js)
        self.assertIn("check-webrtc-ice-reachability.sh", remote_js)
        self.assertIn("MOONLIGHT_EXPERIMENT", remote_js)
        self.assertIn("noVNC admin fallback", remote_html)
        self.assertIn("port {port}", media_py)
        self.assertIn("local ICE candidate", helper_c)

    def test_shell_scripts_have_valid_syntax(self):
        checks = [
            ("bash", "-n", PROJECT_ROOT / "container/entrypoint.sh"),
            ("bash", "-n", PROJECT_ROOT / "container/start-pulseaudio.sh"),
            ("sh", "-n", PROJECT_ROOT / "container/start-websockify.sh"),
            ("sh", "-n", PROJECT_ROOT / "container/healthcheck-novnc.sh"),
            ("bash", "-n", PROJECT_ROOT / "container/patch-novnc.sh"),
            ("sh", "-n", PROJECT_ROOT / "container/latency-proxy.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/generate-tls-certs.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/ensure-tls.sh"),
            ("sh", "-n", PROJECT_ROOT / "container/audio-proxy.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/prepare-nas.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/preflight-nas.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/build-image-nas.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/ingest-assets.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/bootstrap-nas.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/sync-to-nas.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/check-transcode.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/check-host-transcode.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/enable-host-transcode.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/check-av-sync.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/apply-serial-fix.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/check-webrtc-ready.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/redeploy-webrtc.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/redeploy-low-memory.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/check-low-latency-host.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/redeploy-webrtc-udp.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/compare-selkies-webrtc.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/check-webrtc-ice-reachability.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/check-host-prerequisites.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/check-moonlight-ready.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/check-tailscale-direct.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/compare-moonlight-webrtc.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/redeploy-moonlight-poc.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/redeploy-profile-selkies.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/dsm-boot-task.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/enable-uinput.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/prepare-streaming-session.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/redeploy-ultra.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/enable-ultra-player2.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/check-ultra-ready.sh"),
            ("sh", "-n", PROJECT_ROOT / "container/start-game-ultra.sh"),
            ("sh", "-n", PROJECT_ROOT / "container/start-stream-gateway.sh"),
            ("sh", "-n", PROJECT_ROOT / "container/healthcheck-ultra.sh"),
            ("bash", "-n", PROJECT_ROOT / "container/entrypoint-ultra.sh"),
            ("sh", "-n", PROJECT_ROOT / "container/start-x11vnc.sh"),
            ("sh", "-n", PROJECT_ROOT / "container/start-webrtc.sh"),
            ("sh", "-n", PROJECT_ROOT / "container/start-input-proxy.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/admin-rebuild-check.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/verify-deployment.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/validate-env.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/verify-ready.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/lib.sh"),
        ]

        for command in checks:
            with self.subTest(command=" ".join(map(str, command))):
                result = subprocess.run(
                    [str(part) for part in command],
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)


class EntrypointContractTest(unittest.TestCase):
    def test_entrypoint_fails_fast_without_required_identity_and_assets(self):
        entrypoint = read("container/entrypoint.sh")

        self.assertIn("PLAYER_SERIAL is required", entrypoint)
        self.assertIn("VNC_PASSWORD is required", entrypoint)
        self.assertIn('require_file "${ASSETS_DIR}/${GAME_EXE}"', entrypoint)
        self.assertIn('require_file "${ASSETS_DIR}/ddraw.dll"', entrypoint)
        self.assertIn('require_file "${ASSETS_DIR}/ddraw.ini"', entrypoint)
        self.assertIn('require_file "${ASSETS_DIR}/wsock32.dll"', entrypoint)
        self.assertIn("require_cnc_ddraw", entrypoint)
        self.assertIn('grep -aq "cnc-ddraw"', entrypoint)

    def test_entrypoint_initializes_prefix_once_without_copying_assets(self):
        entrypoint = read("container/entrypoint.sh")

        self.assertIn('if [ ! -f "${WINEPREFIX}/.ra2_initialized" ] || ! wine_prefix_ready; then', entrypoint)
        self.assertIn("touch \"${WINEPREFIX}/.ra2_initialized\"", entrypoint)
        self.assertIn("kernel32.dll", entrypoint)
        self.assertIn("wineboot --init", entrypoint)
        self.assertIn("wine_prefix_ready", entrypoint)
        self.assertNotIn("cp -a", entrypoint)
        self.assertIn('GAME_DIR="${WINEPREFIX:-/home/commander/.wine}/drive_c/RA2"', entrypoint)
        self.assertIn('ln -s "$ASSETS_DIR" "$GAME_DIR"', entrypoint)

    def test_entrypoint_configures_wine_for_headless_audio_and_unique_serials(self):
        entrypoint = read("container/entrypoint.sh")

        self.assertIn("Software\\\\Wine\\\\Drivers", entrypoint)
        self.assertIn("/d alsa", entrypoint)
        self.assertIn("WOW6432Node\\\\Westwood\\\\Red Alert 2", entrypoint)
        self.assertIn("WOW6432Node\\\\Westwood\\\\Yuri's Revenge", entrypoint)
        self.assertIn("Software\\\\Westwood\\\\Yuri's Revenge", entrypoint)
        self.assertIn("configure_serial", entrypoint)
        self.assertIn("/d \"$PLAYER_SERIAL\"", entrypoint)

    def test_entrypoint_stores_vnc_password_in_auth_file_not_process_arguments(self):
        entrypoint = read("container/entrypoint.sh")
        supervisor = read("container/supervisord.conf")

        self.assertIn("Applying noVNC audio/video sync tuning", entrypoint)
        self.assertIn("/bin/bash /opt/ra2/patch-novnc.sh /opt/novnc", entrypoint)
        self.assertIn("remote.html", entrypoint)
        self.assertIn("x11vnc -storepasswd \"$VNC_PASSWORD\" /tmp/x11vnc.pass", entrypoint)
        x11vnc = read("container/start-x11vnc.sh")
        self.assertIn("-rfbauth /tmp/x11vnc.pass", x11vnc)
        self.assertIn("/bin/sh /opt/ra2/start-x11vnc.sh", supervisor)
        self.assertNotIn("-passwd %(ENV_VNC_PASSWORD)s", supervisor)


class DisplayPipelineContractTest(unittest.TestCase):
    def test_supervisor_starts_the_browser_display_pipeline_and_game(self):
        supervisor = read("container/supervisord.conf")

        for program in [
            "[program:pulseaudio]",
            "[program:xvfb]",
            "[program:openbox]",
            "[program:x11vnc]",
            "[program:audio-proxy]",
            "[program:latency-proxy]",
            "[program:websockify]",
            "[program:webrtc-media]",
            "[program:webrtc-input]",
            "[program:game]",
        ]:
            self.assertIn(program, supervisor)
        self.assertIn("/bin/sh /opt/ra2/start-webrtc.sh", supervisor)
        self.assertIn("/bin/sh /opt/ra2/start-input-proxy.sh", supervisor)
        self.assertIn("/bin/sh /opt/ra2/start-x11vnc.sh", supervisor)
        self.assertIn("autorestart=unexpected", supervisor)
        self.assertIn("exitcodes=0", supervisor)
        self.assertIn("Xvfb :1 -screen 0 %(ENV_RESOLUTION)sx16", supervisor)
        websockify = read("container/start-websockify.sh")
        self.assertIn('RUNNER="/opt/novnc/utils/websockify/run"', websockify)
        self.assertIn('/bin/sh "$RUNNER"', websockify)
        self.assertIn('--web="$WEB_ROOT"', websockify)
        self.assertIn('--token-source="$TOKEN_CFG"', websockify)
        self.assertIn("--token-plugin TokenFile", websockify)
        self.assertIn("websockify-tokens.cfg", websockify)
        self.assertIn("/bin/sh /opt/ra2/start-websockify.sh", supervisor)
        self.assertIn("/bin/sh /opt/ra2/audio-proxy.sh -l 5711", supervisor)
        self.assertIn("/bin/sh /opt/ra2/latency-proxy.sh -l 5721", supervisor)
        self.assertIn("/bin/sh /opt/ra2/start-pulseaudio.sh", supervisor)
        self.assertIn("/opt/wine/bin/wine /home/commander/game_assets/%(ENV_GAME_EXE)s -SPEEDCONTROL", supervisor)
        self.assertIn('PULSE_SERVER="unix:/tmp/pulse/native"', supervisor)
        self.assertIn('WINEDLLOVERRIDES="mscoree=d;mshtml=d;ddraw=n,b;wsock32=n,b"', supervisor)


class GameConfigContractTest(unittest.TestCase):
    def test_ddraw_template_uses_vnc_safe_windowed_renderer_at_browser_resolution(self):
        ddraw = read("config/ddraw.ini")

        self.assertIn("width=1024", ddraw)
        self.assertIn("height=768", ddraw)
        self.assertIn("fullscreen=false", ddraw)
        self.assertIn("windowed=true", ddraw)
        self.assertIn("renderer=gdi", ddraw)
        self.assertIn("maxfps=24", ddraw)
        self.assertIn("maxgameticks=0", ddraw)
        self.assertIn("minfps=-1", ddraw)
        self.assertNotIn("singlecpu=", ddraw)
        self.assertIn("vsync=false", ddraw)
        self.assertIn("adjmouse=true", ddraw)
        self.assertNotIn("handlemouse=", ddraw)

    def test_ra2_ini_templates_match_display_resolution_and_lan_defaults(self):
        for ini_name in ["config/RA2.ini", "config/RA2MD.ini"]:
            with self.subTest(ini=ini_name):
                config = read(ini_name)
                self.assertIn("AllowHiResModes=yes", config)
                self.assertIn("VideoBackBuffer=no", config)
                self.assertIn("ScreenWidth=1024", config)
                self.assertIn("ScreenHeight=768", config)
                self.assertIn("[Network]", config)

    def test_starcraft_ddraw_stays_at_classic_640x480(self):
        ddraw = read("config/starcraft-ddraw.ini")
        games = json.loads(read("config/games.json"))
        profile = games["starcraft"]

        self.assertIn("width=640", ddraw)
        self.assertIn("height=480", ddraw)
        self.assertIn("renderer=opengl", ddraw)
        self.assertNotIn("renderer=gdi", ddraw)
        self.assertNotIn("hook=2", ddraw)
        self.assertNotIn("nonexclusive=true", ddraw)
        self.assertEqual(profile["gameWidth"], 640)
        self.assertEqual(profile["gameHeight"], 480)
        self.assertIn("starcraft-ddraw.ini", profile["ddrawIni"])

    def test_aoe2_uses_windowed_cnc_ddraw_for_stream_capture(self):
        ddraw = read("config/aoe2-ddraw.ini")
        games = json.loads(read("config/games.json"))
        profile = games["aoe2"]
        prepare = read("container/prepare-aoe2-session.sh")

        self.assertIn("width=800", ddraw)
        self.assertIn("height=600", ddraw)
        self.assertIn("windowed=true", ddraw)
        self.assertIn("fullscreen=false", ddraw)
        self.assertIn("nonexclusive=true", ddraw)
        self.assertEqual(profile["gameWidth"], 800)
        self.assertEqual(profile["gameHeight"], 600)
        self.assertEqual(profile["useCncDdraw"], True)
        self.assertEqual(profile["gameExe"], "EMPIRES2.EXE")
        self.assertIn("comctl32=b", profile["dllOverrides"])
        self.assertIn("ddraw=n,b", profile["dllOverrides"])
        self.assertNotIn("wineLaunchCwdEnv", profile)
        self.assertIn("installed cnc-ddraw", prepare)
        self.assertIn("mount_aoe2_cds", prepare)
        self.assertIn("mount_wine_cd", prepare)
        self.assertIn("install_cd_dlls", prepare)
        self.assertIn("prepare_cd_mount_roots", prepare)
        self.assertIn("CD mirror D: with cracked GAME/EMPIRES2.EXE", prepare)
        self.assertIn("ISO symlinks break Wine dir listing", prepare)
        self.assertIn("register_cd_paths", prepare)
        self.assertIn('CDPath=${base_cd}', prepare)
        self.assertIn('CDPathAge2', prepare)
        self.assertIn('materialize_age2_x1_workdir', prepare)
        self.assertIn("register_wine_cdrom_drives", prepare)
        self.assertIn("InstalledGroup", prepare)
        self.assertIn("ensure_conquerors_data", prepare)
        self.assertIn('/v "d:" /t REG_SZ /d "cdrom"', prepare)
        self.assertIn("C:\\\\AOE2\\\\", prepare)
        self.assertIn("materialize_cracked_exe", prepare)
        run_game = read("container/run-game-session.sh")
        self.assertIn("wineLaunchCwdEnv", run_game)
        self.assertIn("WINE_LAUNCH_CWD", run_game)
        self.assertIn("sync_game_resolution_args", run_game)
        self.assertNotIn('explorer "/desktop=${aoe2_desktop},${aoe2_w}x${aoe2_h}"', run_game)
        gateway = read("container/ra2-stream-gateway.py")
        self.assertIn('"600p": (800, 600)', gateway)

    def test_run_game_session_switches_display_per_game_profile(self):
        run_game = read("container/run-game-session.sh")
        switch = read("container/switch-game-display.sh")
        games = json.loads(read("config/games.json"))

        self.assertIn("maybe_switch_game_display", run_game)
        self.assertIn("switch-game-display.sh", run_game)
        self.assertIn('gameWidth:-1024', run_game)
        self.assertIn('gameHeight:-768', run_game)
        self.assertIn("display-revision", switch)
        self.assertIn("refreshed stream transport revision", switch)
        self.assertEqual(games["starcraft"]["gameWidth"], 640)
        self.assertEqual(games["ra2"]["gameWidth"], 1024)


class NasPreparationContractTest(unittest.TestCase):
    def test_prepare_nas_creates_expected_directory_tree_under_project_root(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "ra2-lan-party"
            env = os.environ.copy()
            env["PROJECT_ROOT"] = str(root)
            env["CONTAINER_UID"] = str(os.getuid())
            env["CONTAINER_GID"] = str(os.getgid())

            result = subprocess.run(
                ["sh", str(PROJECT_ROOT / "scripts/prepare-nas.sh")],
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            for relative in [
                "assets",
                "prefixes/player1-win32",
                "prefixes/player2-win32",
                "project",
                "tls",
                "logs",
            ]:
                self.assertTrue((root / relative).is_dir(), relative)

            assets_mode = stat.S_IMODE((root / "assets").stat().st_mode)
            self.assertEqual(assets_mode, 0o755)


class AutomationScriptsContractTest(unittest.TestCase):
    def test_nas_automation_scripts_exist(self):
        for script in [
            "scripts/lib.sh",
            "scripts/preflight-nas.sh",
            "scripts/build-image-nas.sh",
            "scripts/ingest-assets.sh",
            "scripts/sync-to-nas.sh",
            "scripts/bootstrap-nas.sh",
            "scripts/validate-env.sh",
            "scripts/verify-ready.sh",
            "scripts/check-av-sync.sh",
            "scripts/check-webrtc-ready.sh",
            "scripts/apply-serial-fix.sh",
            "compose.webrtc.yaml",
            "docs/READY.md",
        ]:
            self.assertTrue((PROJECT_ROOT / script).is_file(), script)

    def test_bootstrap_supports_prepare_build_and_launch_modes(self):
        bootstrap = read("scripts/bootstrap-nas.sh")
        for mode in ["prepare", "build", "launch", "status"]:
            self.assertIn(mode, bootstrap)

    def test_validate_env_rejects_placeholder_credentials_and_serials(self):
        validator = read("scripts/validate-env.sh")
        self.assertIn("check_not_default VNC_PASSWORD change-me", validator)
        self.assertIn("check_not_default PLAYER1_SERIAL 11112222333344445555", validator)
        self.assertIn("check_not_default PLAYER2_SERIAL 55554444333322221111", validator)
        self.assertIn('serial1="$(read_env_value PLAYER1_SERIAL "")"', validator)
        self.assertIn('elif [ "$serial1" = "$serial2" ]; then', validator)
        self.assertIn("PROJECT_ROOT must be under Data/App_Development/ra2-lan-party", validator)
        self.assertIn("path_under_root", validator)

    def test_verify_deployment_checks_serial_uniqueness(self):
        verifier = read("scripts/verify-deployment.sh")
        self.assertIn('serial1="$(read_env_value PLAYER1_SERIAL "" "$ENV_FILE")"', verifier)
        self.assertIn('elif [ "$serial1" = "$serial2" ]; then', verifier)
        self.assertIn("PLAYER1_SERIAL and PLAYER2_SERIAL must differ", verifier)

    def test_verify_deployment_checks_browser_audio_stack(self):
        verifier = read("scripts/verify-deployment.sh")
        self.assertIn("Browser audio stack", verifier)
        self.assertIn("audio proxy is listening on port 5711", verifier)
        self.assertIn("PulseAudio is running", verifier)
        self.assertIn("audio proxy is running", verifier)

    def test_verify_deployment_warns_when_https_is_not_enabled(self):
        verifier = read("scripts/verify-deployment.sh")
        self.assertIn("healthcheck-novnc.sh", verifier)
        self.assertIn("docs/HTTPS.md", verifier)
        self.assertIn('scheme="https"', verifier)
        self.assertIn("NAS_PUBLIC_HOSTNAME", verifier)
        self.assertIn("Player 1 remote", verifier)
        self.assertIn("audio proxy handshake returns READY", verifier)
        self.assertIn("Audio/video sync budget", verifier)
        self.assertIn("check-av-sync.sh", verifier)
        self.assertIn("ensure-tls.sh", verifier)
        self.assertIn("check-webrtc-ready.sh", verifier)
        self.assertIn("check-host-prerequisites.sh", verifier)
        self.assertIn("check-moonlight-ready.sh", verifier)
        self.assertIn("check-webrtc-ice-reachability.sh", verifier)
        self.assertIn("WebRTC legacy fallback URLs", verifier)

    def test_lib_sh_supports_opt_in_webrtc_overlay(self):
        lib = read("scripts/lib.sh")
        self.assertIn("webrtc_overlay_enabled", lib)
        self.assertIn("compose.webrtc.yaml", lib)
        self.assertIn("RA2_COMPOSE_WEBRTC", lib)

    def test_lib_sh_supports_opt_in_ultra_overlay(self):
        lib = read("scripts/lib.sh")
        self.assertIn("ultra_overlay_enabled", lib)
        self.assertIn("compose.ultra.yaml", lib)
        self.assertIn("RA2_COMPOSE_ULTRA", lib)

    def test_lib_sh_keeps_transcode_overlay_opt_in(self):
        lib = read("scripts/lib.sh")
        env = read(".env.example")

        self.assertIn("transcode_overlay_enabled", lib)
        self.assertIn("RA2_COMPOSE_TRANSCODE:-0", lib)
        self.assertIn('= "1"', lib)
        self.assertIn("RA2_COMPOSE_TRANSCODE=0", env)

    def test_bootstrap_launch_ensures_tls_and_uses_compose_helper(self):
        bootstrap = read("scripts/bootstrap-nas.sh")
        lib = read("scripts/lib.sh")
        self.assertIn("ensure-tls.sh", bootstrap)
        self.assertIn("run_compose .env up -d --build", bootstrap)
        self.assertIn("tls_material_present", lib)
        self.assertIn("fix_tls_permissions", lib)
        self.assertIn("compose.https.yaml", lib)

    def test_ingest_assets_reads_game_exe_from_env(self):
        ingest = read("scripts/ingest-assets.sh")
        self.assertIn('read_env_value GAME_EXE RA2MD.exe .env', ingest)
        self.assertIn('cp "$COMPOSE_DIR/config/$template" "$ASSETS_DIR/$template"', ingest)
        self.assertIn("RA2MD.INI", ingest)

    def test_sync_excludes_local_metadata_and_env(self):
        sync = read("scripts/sync-to-nas.sh")
        self.assertIn("--exclude='.DS_Store'", sync)
        self.assertIn("--exclude='._*'", sync)
        self.assertIn("--exclude='.env'", sync)

    def test_verify_ready_renders_https_compose_overlay(self):
        verify_ready = read("scripts/verify-ready.sh")
        self.assertIn("compose.yaml + compose.https.yaml render", verify_ready)
        self.assertIn("-f compose.yaml -f compose.https.yaml config", verify_ready)

    def test_tls_generator_includes_public_ddns_hostname(self):
        generator = read("scripts/generate-tls-certs.sh")

        self.assertIn("NAS_PUBLIC_HOSTNAME", generator)
        self.assertIn("Public host:", generator)
        self.assertIn("Player 1 remote", generator)
        self.assertIn("Player 2 remote", generator)

    def test_compose_defines_browser_healthcheck(self):
        compose = read("compose.yaml")
        self.assertIn("healthcheck:", compose)
        self.assertIn("healthcheck-novnc.sh", compose)
        self.assertIn("start-websockify.sh", compose)


class UltraStreamingContractTest(unittest.TestCase):
    def test_ultra_compose_uses_minimal_image_and_single_port_gateway(self):
        compose = read("compose.ultra.yaml")
        dockerfile = read("container/Dockerfile.ultra")
        entrypoint = read("container/entrypoint-ultra.sh")
        minidump = read("container/winedbg-minidump.sh")
        supervisor = read("container/supervisord.ultra.conf")
        game = read("container/start-game-ultra.sh")
        env = env_values()

        self.assertIn("ra2-lan-party:ultra", compose)
        self.assertIn("container/Dockerfile.ultra", compose)
        self.assertIn("WINE_VARIANT: ${WINE_VARIANT:-amd64}", compose)
        self.assertIn("WINE_ARCH: ${WINE_ARCH:-win32}", compose)
        self.assertIn("WINE_ENABLE_MULTILIB: ${WINE_ENABLE_MULTILIB:-1}", compose)
        self.assertIn("ARG WINE_VARIANT=amd64", dockerfile)
        self.assertIn("ARG WINE_ARCH=win32", dockerfile)
        self.assertIn("ARG WINE_ENABLE_MULTILIB=1", dockerfile)
        self.assertIn("WINEARCH=${WINE_ARCH}", dockerfile)
        self.assertIn("[multilib]", dockerfile)
        self.assertIn("lib32-alsa-lib", dockerfile)
        self.assertIn('WINE_ARCH="${WINEARCH:-win64}"', entrypoint)
        self.assertIn('if [ "$WINE_ARCH" = "win32" ]; then', entrypoint)
        self.assertIn('[ ! -f "${WINEPREFIX}/drive_c/windows/syswow64/kernel32.dll" ]', entrypoint)
        self.assertIn("clear_legacy_app_compat", entrypoint)
        self.assertIn("AppDefaults\\\\${exe}", entrypoint)
        self.assertIn('clear_legacy_app_compat "gamemd.exe"', entrypoint)
        self.assertNotIn("RA2_WINE_APP_VERSION", entrypoint)
        self.assertNotIn("win98", entrypoint)
        self.assertIn("x-ra2-ultra-env", compose)
        self.assertIn("ULTRA_VIDEO_FPS: ${ULTRA_VIDEO_FPS:-24}", compose)
        self.assertIn("ULTRA_VIDEO_CODEC: ${ULTRA_VIDEO_CODEC:-H265_10}", compose)
        self.assertNotIn("PLAYER1_GAME_CPUSET", compose)
        self.assertIn('RA2_ENABLE_NOVNC_FALLBACK: "0"', compose)
        self.assertIn('WEBRTC_ENABLED: "0"', compose)
        self.assertIn("ra2-stream-gateway.py", compose)
        self.assertIn("start-game-ultra.sh", compose)
        self.assertIn("winedbg-minidump.sh", compose)
        self.assertIn("winedbg-minidump.sh", dockerfile)
        self.assertIn("winedbg --auto", minidump)
        self.assertIn("winedbg --minidump", minidump)
        self.assertIn("timeout 20", minidump)
        self.assertIn("latest-winedbg-minidump.log", minidump)
        self.assertIn("AeDebug", entrypoint)
        self.assertIn("/bin/sh /opt/ra2/winedbg-minidump.sh %ld %ld", entrypoint)
        self.assertIn("ShowCrashDialog", entrypoint)
        self.assertNotIn("linuxserver/webtop", compose)
        self.assertNotIn("x11vnc", supervisor)
        self.assertNotIn("websockify", supervisor)
        self.assertNotIn("webrtc-media", supervisor)
        self.assertIn("[program:stream-gateway]", supervisor)
        self.assertIn("[program:game]", supervisor)
        self.assertIn("/bin/sh /opt/ra2/start-game-ultra.sh", supervisor)
        self.assertIn("start-xvfb-ultra.sh", supervisor)
        self.assertIn("apply-ultra-display.sh", compose)
        self.assertIn("switch-game-display.sh", compose)
        self.assertIn("ra2-player-dev", compose)
        self.assertIn("tmpfs:", compose)
        self.assertIn("RAM_PREFIX_DIR", compose)
        self.assertIn("RAM_ASSETS_DIR", compose)
        self.assertIn("RAM_TLS_DIR", compose)
        self.assertNotIn("/opt/ra2/ram", compose)
        self.assertIn('DEV_RAM_MEM_LIMIT:-5120m', compose)
        self.assertIn('DEV_RAM_SHM_SIZE:-2048m', compose)
        self.assertIn("DEV_RAM_TMPFS_LOGS", compose)
        self.assertIn("noexec", compose)
        dev_ram = read("scripts/dev-ram-ultra.sh")
        self.assertIn("dev-ram", dev_ram)
        self.assertIn("--profile ram-dev", dev_ram)
        self.assertIn("seed_project_mirror", dev_ram)
        self.assertIn("seed_assets", dev_ram)
        self.assertIn("seed_tls", dev_ram)
        self.assertIn("host_ram_mib", dev_ram)
        self.assertIn("full-RAM profile", dev_ram)
        self.assertIn("refresh", dev_ram)
        self.assertIn("reset-mirror", dev_ram)
        sync_ram = read("scripts/sync-to-ram.sh")
        self.assertIn("sync-to-ram", sync_ram)
        self.assertIn("dev-ram-ultra.sh", sync_ram)
        nas_ram = read("scripts/nas-ram.sh")
        self.assertIn("/dev/shm/ra2-dev/project", nas_ram)
        self.assertIn("nas-ram", nas_ram)
        self.assertIn("startretries=20", supervisor)
        self.assertIn("wait_for_xvfb", game)
        self.assertEqual(env["ULTRA_VIDEO_FPS"], "24")
        self.assertEqual(env["ULTRA_VIDEO_CODEC"], "H265_10")
        self.assertEqual(env["ULTRA_VIDEO_DIAGNOSTICS"], "1")
        self.assertEqual(env["ULTRA_H265_TEST_ENABLED"], "1")
        self.assertEqual(env["RA2_DISPLAY_DEPTH"], "16")
        self.assertNotIn("ULTRA_VIDEO_WIDTH", env)
        self.assertNotIn("ULTRA_VIDEO_HEIGHT", env)
        self.assertEqual(env["ULTRA_AUDIO_CODEC"], "opus")
        self.assertEqual(env["ULTRA_AUDIO_BITRATE"], "64000")
        self.assertEqual(env["ULTRA_AUDIO_RATE"], "48000")
        self.assertEqual(env["ULTRA_AUDIO_TRANSPORT_RATE"], "48000")
        self.assertEqual(env["ULTRA_STREAM_CPUSET"], "2,3")
        self.assertEqual(env["ULTRA_VIDEO_GPU_SCALE"], "1")
        self.assertEqual(env["RA2_COMPOSE_ULTRA"], "1")

    def test_ultra_gateway_and_helper_implement_wss_webcodecs_path(self):
        compose = read("compose.ultra.yaml")
        dockerfile = read("container/Dockerfile.ultra")
        gateway = read("container/ra2-stream-gateway.py")
        helper = read("container/stream-helper.c")
        healthcheck = read("container/healthcheck-ultra.sh")
        start = read("container/start-stream-gateway.sh")
        game = read("container/start-game-ultra.sh")
        session = read("container/run-game-session.sh")
        games_manifest = read("config/games.json")
        self.assertIn("GAME_LAUNCHER_ENABLED", game)
        self.assertIn("run-game-session.sh", game)
        self.assertIn("game-launcher.sh", game)
        self.assertIn("ra2.ini|ra2md.ini|ddraw.ini", session)
        self.assertIn('"ra2"', games_manifest)
        self.assertIn('"aoe2"', games_manifest)
        self.assertIn('"starcraft"', games_manifest)
        diagnostics = read("container/log-video-diagnostics.sh")
        ultra_js = read("container/remote-ultra/ultra-play.js")
        docs = read("docs/ULTRA_LIGHT_ARCH_STREAMING.md")

        self.assertIn("process_request", gateway)
        self.assertIn("urlparse(path).path", gateway)
        self.assertIn("/stream", gateway)
        self.assertIn("ACTIVE_SESSION", gateway)
        self.assertIn("ACTIVE_SESSION_LOCK", gateway)
        self.assertIn("self.replaced", gateway)
        self.assertIn("ULTRA_STREAM_CPUSET", gateway)
        self.assertIn("build_helper_command", gateway)
        self.assertIn("taskset", gateway)
        self.assertIn("ULTRA_STREAM_CPUSET", start)
        self.assertIn("ULTRA_STREAM_CPUSET", compose)
        self.assertIn("ULTRA_VIDEO_GPU_SCALE", helper)
        self.assertIn("vapostproc", helper)
        self.assertIn("video/x-raw(memory:VAMemory),format=%s", helper)
        self.assertIn("gpu_front_active", helper)
        self.assertIn("gpu_front_format", helper)
        self.assertIn("ULTRA_VIDEO_BIT_DEPTH", helper)
        self.assertIn("P010_10LE", helper)
        self.assertIn("profile=main-10", helper)
        self.assertIn("RA2_DISPLAY_DEPTH", compose)
        self.assertIn("RA2_DISPLAY_DEPTH=16", dockerfile)
        self.assertIn("ULTRA_VIDEO_GPU_SCALE", start)
        self.assertIn("ULTRA_VIDEO_GPU_SCALE", compose)
        self.assertIn('line.startswith(\'{"type":"video"\')', gateway)
        self.assertIn("VideoDecoder", ultra_js)
        self.assertIn("WebCodecs", docs)
        self.assertIn("24 fps", docs.lower())
        self.assertIn("ULTRA_VIDEO_CODEC", start)
        self.assertIn("ULTRA_VIDEO_DIAGNOSTICS", start)
        self.assertIn("ULTRA_GST_DEBUG", start)
        self.assertIn("ULTRA_H265_TEST_ENABLED", compose)
        self.assertIn("log-video-diagnostics.sh", compose)
        self.assertIn("log-video-diagnostics.sh", dockerfile)
        self.assertIn("libva-utils", dockerfile)
        self.assertIn("video-diagnostics.log", docs)
        self.assertIn("qsvh265enc", diagnostics)
        self.assertIn("msdkh265enc", diagnostics)
        self.assertIn("vainfo", diagnostics)
        self.assertIn("gst-inspect-1.0", diagnostics)
        self.assertIn("ULTRA_AUDIO_CODEC", start)
        self.assertIn("ULTRA_AUDIO_TRANSPORT_RATE", start)
        self.assertIn("opusenc", helper)
        self.assertIn("ULTRA_AUDIO_BITRATE", helper)
        self.assertIn("ULTRA_AUDIO_RATE", helper)
        self.assertIn("audio_output_rate", helper)
        self.assertIn("vah264enc", helper)
        self.assertIn("qsvh265enc", helper)
        self.assertIn("msdkh265enc", helper)
        self.assertIn("_h265_unavailable_reason", gateway)
        self.assertIn("video-diagnostics.log", gateway)
        self.assertIn("appsink name=vsink", helper)
        self.assertIn("zombie_game_count", session)
        self.assertIn("gamemd.exe", games_manifest)
        self.assertIn("ULTRA_GAME_LOG_ROOT", session)
        self.assertIn("ULTRA_WINEDEBUG", session)
        self.assertIn("wine-current.log", session)
        self.assertIn("RA2_GAME_CPUSET", session)
        self.assertIn("PLAYER_ID} - 1", session)
        self.assertIn('taskset -c "$GAME_CPUSET"', session)
        self.assertIn("pin_game_affinity", session)
        self.assertIn('taskset -pc "$GAME_CPUSET"', session)
        self.assertIn("ULTRA_GAME_WORK_DIR", session)
        self.assertIn("game-work", session)
        self.assertIn("prepare_game_work_dir", session)
        self.assertIn("GAME_OUTPUT_FILES", session)
        self.assertIn('ln -s "$path" "$GAME_DIR/$base"', session)
        self.assertIn("except.txt", session)
        self.assertIn("/opt/wine/bin/wine", session)
        self.assertIn('player${PLAYER_ID:-unknown}', session)
        self.assertIn("sync-game-transport.sh", session)
        self.assertIn("switch-game-display.sh", session)
        self.assertIn("games.json", compose)
        self.assertIn("GAME_LAUNCHER_ENABLED", compose)
        self.assertIn("aoe2_assets", compose)
        self.assertIn("sc_assets", compose)
        self.assertIn("ULTRA_GAME_LOG_ROOT", compose)
        self.assertIn("ra2-logs-root", compose)
        self.assertIn("LOGS_DIR", compose)
        self.assertIn("ULTRA_GAME_LOG_ROOT", gateway)
        self.assertIn("input-events.log", gateway)
        self.assertIn("EMPIRES2.EXE", healthcheck)
        self.assertIn("run-game-session.sh", healthcheck)

    def test_ultra_gateway_restarts_stream_helper_after_unexpected_exit(self):
        gateway = read("container/ra2-stream-gateway.py")
        ultra_js = read("container/remote-ultra/ultra-play.js")

        self.assertIn("_recover_helper_after_exit", gateway)
        self.assertIn('await self._send_ready(reason="helper_restart")', gateway)
        self.assertIn('"DISPLAY": os.environ.get("DISPLAY", ":1")', gateway)
        self.assertIn('os.environ.get("ULTRA_VIDEO_CODEC", "H265_10")', gateway)
        self.assertIn("return (width, height) in GAME_DISPLAY_MODES", gateway)
        self.assertIn("_game_process_running", gateway)
        self.assertIn("_configured_display_dims", gateway)
        self.assertNotIn("scheduleTransportApply()", ultra_js.split("if (msg.type === \"ready\")")[1].split("return;")[0])
        self.assertIn("checkStreamWatchdog", ultra_js)
        self.assertIn('videoCodec: "H265_10"', ultra_js)

    def test_ultra_gateway_normalizes_browser_arrow_keys_for_xdotool(self):
        gateway = read("container/ra2-stream-gateway.py")

        self.assertIn('"ArrowUp": "Up"', gateway)
        self.assertIn('"ArrowDown": "Down"', gateway)
        self.assertIn('"ArrowLeft": "Left"', gateway)
        self.assertIn('"ArrowRight": "Right"', gateway)
        self.assertIn('"Backspace": "BackSpace"', gateway)
        self.assertIn('"Enter": "Return"', gateway)
        self.assertIn("_xdotool_key(key)", gateway)

    def test_ultra_input_releases_held_keys_on_blur_and_disconnect(self):
        gateway = read("container/ra2-stream-gateway.py")
        ultra_js = read("container/remote-ultra/ultra-play.js")

        self.assertIn("active_keys", gateway)
        self.assertIn("OPPOSITE_DIRECTION_KEYS", gateway)
        self.assertIn("ignored-duplicate", gateway)
        self.assertIn("release_opposite", gateway)
        self.assertIn("release_all_keys", gateway)
        self.assertIn('"keyup_all"', gateway)
        self.assertIn('session.input.release_all_keys()', gateway)
        self.assertIn("pressedKeys", ultra_js)
        self.assertNotIn("guardedKeys", ultra_js)
        self.assertNotIn("GUARDED_KEYS", gateway)
        self.assertNotIn("guarded-key", gateway)
        self.assertIn("if (pressedKeys.has(e.key))", ultra_js)
        self.assertIn("releasePressedKeys", ultra_js)
        self.assertIn('window.addEventListener("blur", releasePressedKeys)', ultra_js)
        self.assertIn('window.addEventListener("pagehide", releasePressedKeys)', ultra_js)
        self.assertIn("document.hidden", ultra_js)
        self.assertIn("isGameModeShortcut", ultra_js)
        self.assertIn("handleGameModeEscapeKeyDown", ultra_js)
        self.assertIn("GAME_MODE_ESCAPE_EXIT_MS", ultra_js)
        self.assertIn('window.addEventListener("keydown", handleGameModeShortcut, true)', ultra_js)

    def test_ultra_forwards_all_mouse_buttons_and_wheel(self):
        html = read("container/remote-ultra/index.html")
        gateway = read("container/ra2-stream-gateway.py")
        ultra_js = read("container/remote-ultra/ultra-play.js")

        self.assertIn("object-fit: contain", html)
        self.assertIn("canvasContentRect", ultra_js)
        self.assertIn("if (now - lastMoveAt < moveInterval) return", ultra_js)
        self.assertIn("gameCoordsFromClient", ultra_js)
        self.assertIn("clamp((clientX - rect.left) / rect.width, 0, 1)", ultra_js)
        self.assertIn("clamp((clientY - rect.top) / rect.height, 0, 1)", ultra_js)
        self.assertIn("applyPointerDelta", ultra_js)
        self.assertIn("getCoalescedEvents", ultra_js)
        self.assertIn("virtualGameX + event.movementX", ultra_js)
        self.assertIn("shouldHandlePointerEvent", ultra_js)
        self.assertIn("document.addEventListener(moveEvent, handlePointerMove, true)", ultra_js)
        self.assertIn("requestPointerLock", ultra_js)
        self.assertIn("requestGameModeFullscreen", ultra_js)
        self.assertIn("onFullscreenChange", ultra_js)
        self.assertIn('canvas.addEventListener("dblclick"', ultra_js)
        self.assertNotIn("void toggleGameMode()", ultra_js.split('canvas.addEventListener("dblclick"')[1].split(");")[0])
        self.assertNotIn("dblclickInvolvesControlPanel", ultra_js)
        self.assertIn("requestFullscreen(", ultra_js)
        self.assertIn("fs === gameSurface || fs === canvas", ultra_js)
        self.assertIn("requestPointerLock", ultra_js)
        self.assertIn("gameModeButton", html)
        self.assertIn("game-mode-locked", html)
        self.assertIn("gameSurface", html)
        self.assertIn("cursorOverlay", html)
        self.assertIn("localCursor", html)
        self.assertIn("remoteCursor", html)
        self.assertIn("updateCursorOverlay", ultra_js)
        self.assertIn("gameCoordsToScreen", ultra_js)
        self.assertIn("isGameModeFullscreen", ultra_js)
        self.assertNotIn("flushPendingMove", ultra_js)
        self.assertNotIn("sendMouseDelta", ultra_js)
        self.assertNotIn("mousemove_relative", gateway)
        self.assertIn('sendInput({ type: "wheel", deltaY: e.deltaY })', ultra_js)
        self.assertNotIn('lastInput = "wheel guarded"', ultra_js)
        self.assertNotIn("button ${e.button + 1} ignored", ultra_js)
        self.assertIn("_clamp_int", gateway)
        self.assertIn("self.stream_width - 1", gateway)
        self.assertIn("self.stream_height - 1", gateway)
        self.assertIn("_clamp_int(event.get(\"button\", 1), 1, 9)", gateway)
        self.assertIn('if kind == "wheel":', gateway)
        self.assertIn('direction = "4" if event.get("deltaY", 0) < 0 else "5"', gateway)
        self.assertIn('self._xdotool(["click", direction])', gateway)
        self.assertNotIn("guarded-wheel", gateway)
        self.assertIn("last_wheel_at", gateway)
        self.assertNotIn("ignored-non-left-button", gateway)
        self.assertIn('self._xdotool(["mousedown", str(button)])', gateway)
        self.assertNotIn("_apply_mousemove", gateway)
        self.assertIn('self._xdotool(["mousedown", str(button)])', gateway)
        self.assertIn('self._xdotool(["mouseup", str(button)])', gateway)

    def test_ultra_transport_menu_and_settings_protocol(self):
        html = read("container/remote-ultra/index.html")
        gateway = read("container/ra2-stream-gateway.py")
        ultra_js = read("container/remote-ultra/ultra-play.js")
        docs = read("docs/ULTRA_LIGHT_ARCH_STREAMING.md")

        self.assertIn("controlPanel", html)
        self.assertIn("videoQuality", html)
        self.assertIn("videoCodec", html)
        self.assertIn("videoBitrate", html)
        self.assertIn("videoFps", html)
        self.assertIn("wssVideoFields", html)
        self.assertNotIn("webrtcLatencyPreset", html)
        self.assertIn('<option value="450000">450 kbps</option>', html)
        self.assertIn('<option value="900000">900 kbps</option>', html)
        self.assertIn('<option value="2000000" selected>2.0 Mbps</option>', html)
        self.assertIn('<option value="3500000">3.5 Mbps</option>', html)
        self.assertIn("videoCodecField", html)
        self.assertIn("H.264 Low Latency", html)
        self.assertIn("H.265 10-bit", html)
        self.assertNotIn("H.265 / HEVC 8-bit (hardware)", html)
        self.assertNotIn("H.265 / HEVC 10-bit (hardware)", html)
        self.assertIn('<option value="H265_10"', html)
        self.assertNotIn("audioTest", html)
        self.assertNotIn("Enable audio", html)
        self.assertNotIn("operatingResolution", html)
        self.assertNotIn("streamResolution", html)
        self.assertIn("audioEncoder", html)
        self.assertIn("audioBitrate", html)
        self.assertIn("audioQuality", html)
        self.assertIn("inputMoveHz", html)
        self.assertIn("transportStatus", html)
        self.assertIn('<option value="opus" selected>Opus low-latency</option>', html)
        self.assertIn('<option value="64000" selected>64 kbps</option>', html)
        self.assertIn("validate_settings", gateway)
        self.assertIn("_restart_webrtc_media", gateway)
        self.assertIn("_write_webrtc_runtime_codec", gateway)
        self.assertIn("WEBRTC_RUNTIME_CODEC_FILE", gateway)
        self.assertNotIn("webrtcLatencyPreset", gateway)
        self.assertIn("ALLOWED_VIDEO_BITRATES", gateway)
        self.assertIn("ALLOWED_VIDEO_FPS", gateway)
        self.assertIn("300000", gateway)
        self.assertIn("3500000", gateway)
        self.assertIn("450000", gateway)
        self.assertIn('"videoBitrate"', gateway)
        self.assertIn('"videoFps"', gateway)
        self.assertIn("_h265_unavailable_reason", gateway)
        self.assertIn("H265_TEST_ENABLED", gateway)
        self.assertIn("ULTRA_H265_TEST_ENABLED", gateway)
        self.assertIn("QSV HEVC", gateway)
        self.assertIn("video-diagnostics.log", gateway)
        self.assertIn("H265_10", gateway)
        self.assertIn("_vah265enc_supports_p010", gateway)
        self.assertIn("_h265_10_unavailable_reason", gateway)
        self.assertIn("ULTRA_VIDEO_BIT_DEPTH", gateway)
        self.assertIn("ALLOWED_VIDEO_RESOLUTIONS", gateway)
        self.assertIn("GAME_DISPLAY_MODES", gateway)
        self.assertIn("MAX_VIDEO_FPS", gateway)
        self.assertIn("displayResolution", gateway)
        self.assertIn("_configured_display_dims", gateway)
        display_dims_fn = gateway.split("def _display_dims", 1)[1].split("\ndef ", 1)[0]
        self.assertNotIn("ULTRA_VIDEO_WIDTH", display_dims_fn)
        self.assertIn("DISPLAY_REVISION", gateway)
        self.assertIn("watch_display_revision", gateway)
        self.assertIn('"display_change"', gateway)
        self.assertIn("SPECTATOR_SESSIONS", gateway)
        self.assertIn("attach_as_spectator", gateway)
        self.assertIn("_sync_spectators_ready", gateway)
        self.assertIn("resolveActiveVideoDecoderCodec", ultra_js)
        self.assertIn("recoverVideoPresentation", ultra_js)
        self.assertIn("onDisplayLayoutChange", ultra_js)
        self.assertIn("watchStreamButton.addEventListener", ultra_js)
        self.assertNotIn("presence.controllerStreaming) {\n        void watchStream()", ultra_js)
        self.assertNotIn("if (controllerStreaming) {\n          void watchStream()", ultra_js)
        self.assertNotIn("_live_display_dims", gateway)
        self.assertNotIn("ensure_native_display", gateway)
        self.assertNotIn("_watch_game_display", gateway)
        self.assertIn("reconfigure", gateway)
        self.assertIn("INPUT_MESSAGE_TYPES", gateway)
        self.assertIn("VIDEO_TRANSPORT_FIELDS", gateway)
        self.assertIn("asyncio.create_task", gateway)
        self.assertIn("helper_needs_restart", gateway)
        self.assertIn("GAME_WINDOW_PATTERNS", gateway)
        self.assertIn("set_display_sizes", gateway)
        self.assertIn("_sync_stream_state", gateway)
        self.assertIn("ULTRA_STREAM_CODEC_LOCK", gateway)
        self.assertIn("streamCodecLock", gateway)
        self.assertNotIn("skipping stream helper restart during gameplay", gateway)
        self.assertNotIn("gamemd started; pausing X11 capture", gateway)
        self.assertNotIn("map_load_pause", gateway)
        self.assertIn("ensure-game-ini-links.sh", gateway)
        self.assertIn("server locked to H264 for stable mission play", gateway)
        self.assertIn("_sync_audio_transport", gateway)
        self.assertIn("sync-audio-transport.sh", gateway)
        self.assertIn("urlparse(path).path", gateway)
        self.assertIn("selectGame", gateway)
        self.assertIn("attach_as_spectator", gateway)
        self.assertIn("controllerBusy", gateway)
        self.assertIn("selectGame", ultra_js)
        self.assertIn("showClickToConnect", ultra_js)
        self.assertIn("picker-open", ultra_js)
        self.assertIn("_map_xy", gateway)
        self.assertIn("VideoDecoder configure failed", ultra_js)
        self.assertIn("video decoder decode", ultra_js)
        self.assertIn("supportedVideoDecoderCodec", ultra_js)
        self.assertIn("HEVC VideoDecoder unsupported in this browser", ultra_js)
        self.assertIn("hvc1.1.6.L93.B0", ultra_js)
        self.assertIn("webrtc-ice-utils.js", html)
        self.assertIn("Ra2WebRtcIceUtils", read("container/remote-ultra/webrtc-ice-utils.js"))
        self.assertIn("run-deploy-tests.sh", read("scripts/redeploy-ultra.sh"))
        self.assertIn("run-webrtc-tests.sh", read("scripts/run-deploy-tests.sh"))
        self.assertIn("verify-aoe2-session.sh", read("scripts/redeploy-ultra.sh"))
        self.assertIn("AOE2_CD_PATH:-C:", read("scripts/verify-aoe2-session.sh"))
        self.assertIn("test_remote_webrtc_contract", read("scripts/run-webrtc-tests.sh"))
        self.assertIn("sdpHasUsableLocalIce", read("container/remote-ultra/webrtc-ice-utils.js"))
        self.assertIn("udp video: WebRTC verified", ultra_js)
        self.assertIn("webrtcMediaVerified", ultra_js)
        self.assertIn("videoBytes += data.length", ultra_js)
        self.assertIn("hev1.1.6.L93.B0", ultra_js)
        self.assertNotIn("hevc1.1.6.L93.B0", ultra_js)
        self.assertIn("hev1.2.4.L93.B0", ultra_js)
        self.assertIn("hvc1.2.4.L93.B0", ultra_js)
        self.assertIn("10-bit HEVC VideoDecoder unsupported in this browser", ultra_js)
        self.assertIn('videoCodec: "H265_10"', ultra_js)
        self.assertNotIn("operatingResolutionEl", ultra_js)
        self.assertNotIn("streamResolutionEl", ultra_js)
        self.assertIn("onDisplayLayoutChange", ultra_js)
        self.assertIn("parseDisplayResolution", ultra_js)
        self.assertIn("applyTransportSettings", ultra_js)
        self.assertIn("scheduleTransportApply", ultra_js)
        self.assertIn("reconfigure", ultra_js)
        self.assertIn("videoTransportKey", ultra_js)
        self.assertIn("appliedVideoTransportKey", ultra_js)
        self.assertIn("maybeRecoverWebRtcBlackVideo", ultra_js)
        self.assertIn("sampleWebRtcVideoLuminance", ultra_js)
        self.assertIn("transportApplyFields", ultra_js)
        self.assertIn("settingsForTransportMode", ultra_js)
        apply_display = read("container/apply-ultra-display.sh")
        self.assertIn("read_display_dims", apply_display)
        self.assertIn("supervisorctl", apply_display)
        self.assertIn("xdpyinfo", apply_display)
        self.assertIn("sync-game-transport.sh", apply_display)
        self.assertIn("gamemd is running; refusing display change", apply_display)
        pulse_launcher = read("container/start-pulseaudio.sh")
        self.assertIn("sync-audio-transport.sh", pulse_launcher)
        sync_audio = read("container/sync-audio-transport.sh")
        self.assertIn("module-simple-protocol-tcp", sync_audio)
        self.assertIn("audio-native-rate", sync_audio)
        sync_transport = read("container/sync-game-transport.sh")
        self.assertIn("gamemd is running; refusing to rewrite game-work configs", sync_transport)
        self.assertIn("rm -f \"${GAME_WORK}/ra2.ini\"", sync_transport)
        self.assertIn("link_ini_alias RA2MD.ini ra2.ini", sync_transport)
        self.assertIn("VideoBackBuffer", sync_transport)
        self.assertIn("maxfps=", sync_transport)
        self.assertIn("vsync=false", sync_transport)
        self.assertIn("/^handlemouse=/ { next }", sync_transport)
        self.assertIn("ScreenWidth", sync_transport)
        stream_helper = read("container/stream-helper.c")
        self.assertIn("drop-only=true", stream_helper)
        self.assertIn("setStreamFps", ultra_js)
        self.assertIn("scheduleVideoPresent", ultra_js)
        self.assertIn("requestVideoFrameCallback", ultra_js)
        configure_modes = read("container/configure-display-modes.sh")
        self.assertIn("640x480", configure_modes)
        self.assertIn("800x600", configure_modes)
        self.assertIn("1024x768", configure_modes)
        self.assertIn("960x720", configure_modes)
        self.assertIn("1440x1080", configure_modes)
        xvfb = read("container/start-xvfb-ultra.sh")
        self.assertIn("RESOLUTION", xvfb)
        self.assertIn("exec /usr/bin/Xvfb", xvfb)
        supervisor = read("container/supervisord.ultra.conf")
        self.assertIn("[unix_http_server]", supervisor)
        self.assertIn("[supervisorctl]", supervisor)
        self.assertIn('"fallbacks"', gateway)
        self.assertIn('"available"', gateway)
        self.assertIn('audioEncoder: "opus"', ultra_js)
        self.assertIn('videoBitrate: "2000000"', ultra_js)
        self.assertIn('videoFps: "24"', ultra_js)
        self.assertIn('inputMoveHz: "60"', ultra_js)
        self.assertIn("videoBitrateEl", ultra_js)
        self.assertIn("videoFpsEl", ultra_js)
        self.assertIn('"videoCodec"', ultra_js)
        self.assertIn("UDP_VIDEO_FIELDS", ultra_js)
        self.assertIn("available.videoBitrate", ultra_js)
        self.assertIn("available.videoFps", ultra_js)
        self.assertIn('audioBitrate: "64000"', ultra_js)
        self.assertIn("AudioDecoder", ultra_js)
        self.assertIn('format: "f32-planar"', ultra_js)
        self.assertIn("supportsOpusAudioDecoder", ultra_js)
        self.assertIn("browserCompatibleSettings", ultra_js)
        self.assertIn("Opus AudioDecoder unsupported in this browser", ultra_js)
        self.assertIn("unlockAudio", ultra_js)
        self.assertNotIn("enableSelectedAudio", ultra_js)
        self.assertIn("audioOutputStatus", ultra_js)
        self.assertIn("audioPeak", ultra_js)
        self.assertIn("resetAudioPlayback", ultra_js)
        self.assertNotIn("playElementTone", ultra_js)
        self.assertNotIn("audio/wav", ultra_js)
        self.assertNotIn("new Audio(", ultra_js)
        self.assertIn("webkitAudioContext", ultra_js)
        self.assertIn("audioTransportRate", ultra_js)
        self.assertIn("applyActiveAudioFromServer", ultra_js)
        self.assertIn("activeAudioRate", ultra_js)
        self.assertNotIn("activeNativeAudioRate", ultra_js)
        self.assertNotIn("activeTransportAudioRate", ultra_js)
        gateway_audio = read("container/ra2-stream-gateway.py")
        self.assertIn('active["audioTransportRate"] = native_rate', gateway_audio)
        self.assertNotIn("48000 if audio_encoder == \"opus\"", gateway_audio)
        self.assertIn("audioStreamClock", ultra_js)
        self.assertIn("AUDIO_START_LEAD_S", ultra_js)
        self.assertIn("scheduleAudioBuffer", ultra_js)
        helper_c = read("container/stream-helper.c")
        self.assertIn("audio/x-raw,format=S16LE,rate=%d,channels=2", helper_c)
        self.assertIn("audio_queue", helper_c)
        self.assertIn("leaky=no", helper_c)
        self.assertNotIn("ignored unexpected audio codec", ultra_js)
        self.assertIn("localStorage", ultra_js)
        self.assertIn("settings", ultra_js)
        self.assertIn("live over the existing WebSocket", docs)

    def test_ultra_deploy_and_check_scripts_exist(self):
        redeploy = read("scripts/redeploy-ultra.sh")
        check = read("scripts/check-ultra-ready.sh")

        self.assertIn("RA2_COMPOSE_ULTRA=1", redeploy)
        self.assertIn("ra2-player-1 ra2-player-2", redeploy)
        self.assertIn("stream-helper", redeploy)
        self.assertIn("websockify should be disabled", redeploy)
        self.assertIn("RA2_COMPOSE_ULTRA", check)
        self.assertIn("vah264enc", check)
        self.assertIn("ULTRA_LIGHT_ARCH_STREAMING.md", check)


class DocumentationContractTest(unittest.TestCase):
    def test_deployment_docs_cover_manual_gates_and_player_urls(self):
        docs = read("docs/DEPLOY_SYNOLOGY.md")

        for expected in [
            "## 1. Copy Project To NAS",
            "## 2. Prepare NAS Folders",
            "/volume2/Data/App_Development/ra2-lan-party/assets",
            "ipxwrapper.ini",
            "ddraw.dll",
            "wsock32.dll",
            "PLAYER1_SERIAL",
            "PLAYER2_SERIAL",
            "172.22.20.0/24",
            "docs/HTTPS.md",
            "compose.https.yaml",
            "https://192.168.0.193:6081/vnc.html",
            "https://192.168.0.193:6082/vnc.html",
            "https://peterjfrancoiii2.synology.me:6081/vnc.html",
            "https://peterjfrancoiii2.synology.me:6082/vnc.html",
            "external TCP `6081`",
            "external TCP `6082`",
            "RA2_COMPOSE_WEBRTC=1",
            "remote.html?signal=6083&input=6085",
            "TCP `6081-6086`",
            "UDP `62001-62040`",
            "secure context",
            "2 GB DS225+ is an OOM risk",
            "6 GB",
            "docs/MOONLIGHT_EXPERIMENT.md",
            "docs/CONSOLIDATED_ARCHITECTURE.md",
            "docs/TAILSCALE.md",
            "compose.sunshine.yaml",
            "compose.wolf.yaml",
            "check-host-prerequisites.sh",
            "check-webrtc-ice-reachability.sh",
            "legacy browser fallback",
            "sh scripts/bootstrap-nas.sh prepare",
            "sh scripts/validate-env.sh",
        ]:
            self.assertIn(expected, docs)

    def test_readme_states_asset_boundary_and_quick_start(self):
        readme = read("README.md")

        self.assertIn("No copyrighted game files", readme)
        self.assertIn("sh scripts/bootstrap-nas.sh launch", readme)
        self.assertIn("docs/MOONLIGHT_EXPERIMENT.md", readme)
        self.assertIn("docs/ULTRA_LIGHT_ARCH_STREAMING.md", readme)
        self.assertIn("Ultra Arch Browser", readme)
        self.assertIn("docs/TAILSCALE.md", readme)
        self.assertIn("compose.sunshine.yaml", readme)
        self.assertIn("archived legacy fallback", readme.lower())
        self.assertIn("RA2_COMPOSE_TRANSCODE=1", readme)
        self.assertIn("compose.https.yaml", readme)
        self.assertIn("docs/HTTPS.md", readme)
        self.assertIn("172.22.20.11", readme)
        self.assertIn("172.22.20.12", readme)


if __name__ == "__main__":
    unittest.main(verbosity=2)
