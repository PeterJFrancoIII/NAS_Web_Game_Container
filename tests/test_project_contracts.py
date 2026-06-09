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

    def test_transcode_overlay_grants_gpu_access_without_changing_default_stack(self):
        compose = read("compose.yaml")
        overlay = read("compose.transcode.yaml")

        self.assertNotIn("/dev/dri", compose)
        self.assertIn("${DRI_DEVICE:-/dev/dri}:/dev/dri", overlay)
        self.assertIn("${RENDER_GID:-937}", overlay)
        self.assertIn("${VIDEO_GID:-44}", overlay)
        self.assertIn("LIBVA_DRIVER_NAME: ${LIBVA_DRIVER_NAME:-i965}", overlay)


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
            "xorg-server-xvfb",
            "openbox",
            "x11vnc",
            "supervisor",
            "mesa",
            "python",
        ]:
            self.assertIn(package, dockerfile)
        self.assertIn("LIBVA_DRIVER_NAME=i965", dockerfile)
        self.assertIn("rm -f /usr/lib/dri/iHD_drv_video.so", dockerfile)
        self.assertNotIn("intel-media-driver", dockerfile)
        self.assertIn("GST_VAAPI_ALL_DRIVERS=1", dockerfile)
        self.assertIn("useradd -m -u 1000 -s /bin/bash commander", dockerfile)
        self.assertIn("COPY container/asound.conf /etc/asound.conf", dockerfile)
        self.assertIn("USER commander", dockerfile)

    def test_shell_scripts_have_valid_syntax(self):
        checks = [
            ("bash", "-n", PROJECT_ROOT / "container/entrypoint.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/prepare-nas.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/preflight-nas.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/build-image-nas.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/ingest-assets.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/bootstrap-nas.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/sync-to-nas.sh"),
            ("sh", "-n", PROJECT_ROOT / "scripts/check-transcode.sh"),
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
        self.assertIn("/d \"$PLAYER_SERIAL\"", entrypoint)

    def test_entrypoint_stores_vnc_password_in_auth_file_not_process_arguments(self):
        entrypoint = read("container/entrypoint.sh")
        supervisor = read("container/supervisord.conf")

        self.assertIn("x11vnc -storepasswd \"$VNC_PASSWORD\" /tmp/x11vnc.pass", entrypoint)
        self.assertIn("-rfbauth /tmp/x11vnc.pass", supervisor)
        self.assertNotIn("-passwd %(ENV_VNC_PASSWORD)s", supervisor)


class DisplayPipelineContractTest(unittest.TestCase):
    def test_supervisor_starts_the_browser_display_pipeline_and_game(self):
        supervisor = read("container/supervisord.conf")

        for program in [
            "[program:xvfb]",
            "[program:openbox]",
            "[program:x11vnc]",
            "[program:websockify]",
            "[program:game]",
        ]:
            self.assertIn(program, supervisor)
        self.assertIn("Xvfb :1 -screen 0 %(ENV_RESOLUTION)sx16", supervisor)
        self.assertIn("/opt/novnc/utils/websockify/run 6080 localhost:5900 --web /opt/novnc", supervisor)
        self.assertIn("/opt/wine/bin/wine /home/commander/game_assets/%(ENV_GAME_EXE)s -SPEEDCONTROL", supervisor)
        self.assertIn('WINEDLLOVERRIDES="mscoree=d;mshtml=d;ddraw=n,b;wsock32=n,b"', supervisor)


class GameConfigContractTest(unittest.TestCase):
    def test_ddraw_template_uses_vnc_safe_windowed_renderer_at_browser_resolution(self):
        ddraw = read("config/ddraw.ini")

        self.assertIn("width=1024", ddraw)
        self.assertIn("height=768", ddraw)
        self.assertIn("fullscreen=false", ddraw)
        self.assertIn("windowed=true", ddraw)
        self.assertIn("renderer=gdi", ddraw)
        self.assertIn("maxfps=60", ddraw)

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

    def test_compose_defines_browser_healthcheck(self):
        compose = read("compose.yaml")
        self.assertIn("healthcheck:", compose)
        self.assertIn("http://127.0.0.1:6080/", compose)


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
            "http://192.168.0.193:6081/",
            "http://192.168.0.193:6082/",
            "2 GB DS225+ is an OOM risk",
            "sh scripts/bootstrap-nas.sh prepare",
            "sh scripts/validate-env.sh",
        ]:
            self.assertIn(expected, docs)

    def test_readme_states_asset_boundary_and_quick_start(self):
        readme = read("README.md")

        self.assertIn("No copyrighted game files", readme)
        self.assertIn("docker compose --env-file .env up -d --build", readme)
        self.assertIn("172.22.20.11", readme)
        self.assertIn("172.22.20.12", readme)


if __name__ == "__main__":
    unittest.main(verbosity=2)
