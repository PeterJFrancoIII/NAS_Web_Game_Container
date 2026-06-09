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
        self.assertEqual(values["PREFIX1_DIR"], "/volume2/Data/App_Development/ra2-lan-party/prefixes/player1")
        self.assertEqual(values["PREFIX2_DIR"], "/volume2/Data/App_Development/ra2-lan-party/prefixes/player2")

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
        self.assertEqual(values["NAS_LAN_IP"], "192.168.0.193")
        self.assertEqual(values["NAS_PUBLIC_HOSTNAME"], "peterjfrancoiii2.synology.me")
        self.assertIn("/ra2-lan-party/tls", values["TLS_DIR"])
        self.assertEqual(values["DRI_DEVICE"], "/dev/dri")
        self.assertEqual(values["RENDER_GID"], "937")
        self.assertEqual(values["LIBVA_DRIVER_NAME"], "i965")
        self.assertNotEqual(values["PLAYER1_SERIAL"], values["PLAYER2_SERIAL"])
        self.assertNotEqual(values["PLAYER1_VNC_PASSWORD"], values["PLAYER2_VNC_PASSWORD"])
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
        self.assertIn("ipv4_address: 172.22.20.11", compose)
        self.assertIn("ipv4_address: 172.22.20.12", compose)
        self.assertIn("subnet: 172.22.20.0/24", compose)
        self.assertIn("gateway: 172.22.20.1", compose)
        self.assertIn("driver: bridge", compose)

    def test_compose_exposes_browser_display_ports_without_exposing_vnc_directly(self):
        compose = read("compose.yaml")

        self.assertIn('"${PLAYER1_HTTP_PORT:-6081}:6080/tcp"', compose)
        self.assertIn('"${PLAYER2_HTTP_PORT:-6082}:6080/tcp"', compose)
        self.assertNotIn(":5900", compose)

    def test_compose_requires_runtime_secrets_from_env(self):
        compose = read("compose.yaml")

        self.assertIn("${PLAYER1_SERIAL:?set PLAYER1_SERIAL in .env}", compose)
        self.assertIn("${PLAYER2_SERIAL:?set PLAYER2_SERIAL in .env}", compose)
        self.assertIn("${PLAYER1_VNC_PASSWORD:?set PLAYER1_VNC_PASSWORD in .env}", compose)
        self.assertIn("${PLAYER2_VNC_PASSWORD:?set PLAYER2_VNC_PASSWORD in .env}", compose)
        self.assertNotIn("PLAYER_SERIAL: ${PLAYER1_SERIAL:-", compose)
        self.assertNotIn("VNC_PASSWORD: ${PLAYER1_VNC_PASSWORD:-", compose)

    def test_compose_mounts_shared_assets_read_only_and_prefixes_read_write(self):
        compose = read("compose.yaml")

        self.assertIn("/home/commander/game_assets:ro", compose)
        self.assertIn("/prefixes/player1}:/home/commander/.wine:rw", compose)
        self.assertIn("/prefixes/player2}:/home/commander/.wine:rw", compose)
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
        self.assertIn("${PLAYER1_WEBRTC_SIGNAL_PORT:-6083}:6090/tcp", overlay)
        self.assertIn("${PLAYER2_WEBRTC_SIGNAL_PORT:-6084}:6090/tcp", overlay)
        self.assertIn("${PLAYER1_WEBRTC_INPUT_PORT:-6085}:5731/tcp", overlay)
        self.assertIn("${PLAYER2_WEBRTC_INPUT_PORT:-6086}:5731/tcp", overlay)
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

        self.assertIn("rate=44100", pulse)
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
        self.assertIn("--file=/opt/ra2/pulse/default.pa", pulse_launcher)
        self.assertIn("mkdir -p /tmp/pulse", pulse_launcher)
        self.assertNotIn("--script=", pulse_launcher)
        self.assertNotIn("rate=48000", pulse)

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
        webrtc = read("container/webrtc-media.py")
        input_proxy = read("container/input-proxy.py")
        remote_js = read("container/remote/remote-play.js")

        self.assertIn("ximagesrc", webrtc)
        self.assertIn("tcpclientsrc", webrtc)
        self.assertIn("webrtcbin", webrtc)
        self.assertIn("WEBRTC_UDP_PORT_MIN", webrtc)
        self.assertIn("xdotool", input_proxy)
        self.assertIn("RTCPeerConnection", remote_js)
        self.assertIn("WebSocket", remote_js)

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
        self.assertIn("-rfbauth /tmp/x11vnc.pass", supervisor)
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
        self.assertIn("maxfps=20", ddraw)

    def test_ra2_ini_templates_match_display_resolution_and_lan_defaults(self):
        for ini_name in ["config/RA2.ini", "config/RA2MD.ini"]:
            with self.subTest(ini=ini_name):
                config = read(ini_name)
                self.assertIn("AllowHiResModes=yes", config)
                self.assertIn("VideoBackBuffer=no", config)
                self.assertIn("ScreenWidth=1024", config)
                self.assertIn("ScreenHeight=768", config)
                self.assertIn("[Network]", config)


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
                "prefixes/player1",
                "prefixes/player2",
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
        self.assertIn("check_not_default PLAYER1_VNC_PASSWORD change-player1", validator)
        self.assertIn("check_not_default PLAYER2_VNC_PASSWORD change-player2", validator)
        self.assertIn("check_not_default PLAYER1_SERIAL 11112222333344445555", validator)
        self.assertIn("check_not_default PLAYER2_SERIAL 55554444333322221111", validator)
        self.assertIn('serial1="$(read_env_value PLAYER1_SERIAL "")"', validator)
        self.assertIn('elif [ "$serial1" = "$serial2" ]; then', validator)

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
        self.assertIn("WebRTC remote play URLs", verifier)

    def test_lib_sh_supports_opt_in_webrtc_overlay(self):
        lib = read("scripts/lib.sh")
        self.assertIn("webrtc_overlay_enabled", lib)
        self.assertIn("compose.webrtc.yaml", lib)
        self.assertIn("RA2_COMPOSE_WEBRTC", lib)

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
            "sh scripts/bootstrap-nas.sh prepare",
            "sh scripts/validate-env.sh",
        ]:
            self.assertIn(expected, docs)

    def test_readme_states_asset_boundary_and_quick_start(self):
        readme = read("README.md")

        self.assertIn("No copyrighted game files", readme)
        self.assertIn("docker compose --env-file .env up -d --build", readme)
        self.assertIn("compose.https.yaml", readme)
        self.assertIn("docs/HTTPS.md", readme)
        self.assertIn("172.22.20.11", readme)
        self.assertIn("172.22.20.12", readme)


if __name__ == "__main__":
    unittest.main(verbosity=2)
