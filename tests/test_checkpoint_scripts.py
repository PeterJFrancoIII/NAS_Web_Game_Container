import os
import shlex
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
TEST_TMP_ROOT = PROJECT_ROOT / ".test-tmp"


def temp_workspace():
    TEST_TMP_ROOT.mkdir(exist_ok=True)
    return tempfile.TemporaryDirectory(dir=TEST_TMP_ROOT)


def run_script(script, *, cwd=None, env=None):
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)

    return subprocess.run(
        ["sh", "-c", script],
        cwd=cwd or PROJECT_ROOT,
        env=merged_env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def write_executable(path, content):
    path.write_text(textwrap.dedent(content).lstrip(), encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class TlsCheckpointUnitTest(unittest.TestCase):
    def test_tls_helpers_find_material_from_env_and_reject_wrong_owner(self):
        with temp_workspace() as temp_dir:
            root = Path(temp_dir)
            tls_dir = root / "tls"
            tls_dir.mkdir()
            (tls_dir / "cert.pem").write_text("cert", encoding="utf-8")
            (tls_dir / "key.pem").write_text("key", encoding="utf-8")
            env_file = root / ".env"
            env_file.write_text(f"TLS_DIR={tls_dir}\n", encoding="utf-8")

            result = run_script(
                f"""
                . "{PROJECT_ROOT / 'scripts/lib.sh'}"
                tls_material_present "{env_file}" && echo material-present
                echo "cert=$(tls_cert_path "{env_file}")"
                echo "key=$(tls_key_path "{env_file}")"
                if tls_key_usable_by_container "{env_file}"; then
                  echo key-usable
                else
                  echo key-not-usable
                fi
                """
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("material-present", result.stdout)
            self.assertIn(f"cert={tls_dir / 'cert.pem'}", result.stdout)
            self.assertIn(f"key={tls_dir / 'key.pem'}", result.stdout)
            self.assertIn("key-not-usable", result.stdout)

    def test_fix_tls_permissions_makes_material_usable_by_container_uid(self):
        with temp_workspace() as temp_dir:
            root = Path(temp_dir)
            tls_dir = root / "tls"
            tls_dir.mkdir()
            cert = tls_dir / "cert.pem"
            key = tls_dir / "key.pem"
            cert.write_text("cert", encoding="utf-8")
            key.write_text("key", encoding="utf-8")
            env_file = root / ".env"
            env_file.write_text(f"TLS_DIR={tls_dir}\n", encoding="utf-8")

            try:
                os.chown(cert, 1000, 1000)
                os.chown(key, 1000, 1000)
            except OSError as exc:
                self.skipTest(f"cannot chown test TLS files to uid 1000: {exc}")

            result = run_script(
                f"""
                . "{PROJECT_ROOT / 'scripts/lib.sh'}"
                fix_tls_permissions "{env_file}"
                if tls_key_usable_by_container "{env_file}"; then
                  echo key-usable
                fi
                """
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("key-usable", result.stdout)

    def test_run_compose_adds_https_overlay_only_when_tls_material_exists(self):
        with temp_workspace() as temp_dir:
            root = Path(temp_dir)
            tls_dir = root / "tls"
            tls_dir.mkdir()
            env_file = root / ".env"
            env_file.write_text(f"TLS_DIR={tls_dir}\n", encoding="utf-8")
            (root / "compose.yaml").write_text("services: {}\n", encoding="utf-8")
            (root / "compose.https.yaml").write_text("services: {}\n", encoding="utf-8")

            fake_docker = root / "docker"
            docker_log = root / "docker.args"
            write_executable(
                fake_docker,
                f"""
                #!/bin/sh
                echo "$@" >> "{docker_log}"
                if [ "$1" = info ]; then exit 0; fi
                exit 0
                """,
            )

            result_without_tls = run_script(
                f'. "{PROJECT_ROOT / "scripts/lib.sh"}"; run_compose "{env_file}" ps',
                cwd=root,
                env={"DOCKER": str(fake_docker)},
            )
            self.assertEqual(result_without_tls.returncode, 0, result_without_tls.stderr)
            log_text = docker_log.read_text(encoding="utf-8")
            self.assertIn(f"compose --env-file {env_file}", log_text)
            self.assertIn("-f compose.yaml", log_text)
            self.assertIn(" ps", log_text)

            (tls_dir / "cert.pem").write_text("cert", encoding="utf-8")
            (tls_dir / "key.pem").write_text("key", encoding="utf-8")
            docker_log.write_text("", encoding="utf-8")

            result_with_tls = run_script(
                f'. "{PROJECT_ROOT / "scripts/lib.sh"}"; run_compose "{env_file}" up -d',
                cwd=root,
                env={"DOCKER": str(fake_docker)},
            )
            self.assertEqual(result_with_tls.returncode, 0, result_with_tls.stderr)
            tls_log = docker_log.read_text(encoding="utf-8")
            self.assertIn(f"compose --env-file {env_file}", tls_log)
            self.assertIn("-f compose.yaml", tls_log)
            self.assertIn("-f compose.https.yaml up -d", tls_log)

    def test_run_compose_adds_transcode_overlay_only_when_enabled(self):
        with temp_workspace() as temp_dir:
            root = Path(temp_dir)
            tls_dir = root / "tls"
            tls_dir.mkdir()
            (tls_dir / "cert.pem").write_text("cert", encoding="utf-8")
            (tls_dir / "key.pem").write_text("key", encoding="utf-8")
            env_file = root / ".env"
            env_file.write_text(f"TLS_DIR={tls_dir}\n", encoding="utf-8")
            (root / "compose.yaml").write_text("services: {}\n", encoding="utf-8")
            (root / "compose.https.yaml").write_text("services: {}\n", encoding="utf-8")
            (root / "compose.transcode.yaml").write_text("services: {}\n", encoding="utf-8")

            fake_docker = root / "docker"
            docker_log = root / "docker.args"
            write_executable(
                fake_docker,
                f"""
                #!/bin/sh
                echo "$@" >> "{docker_log}"
                if [ "$1" = info ]; then exit 0; fi
                exit 0
                """,
            )

            result = run_script(
                f'. "{PROJECT_ROOT / "scripts/lib.sh"}"; run_compose "{env_file}" up -d',
                cwd=root,
                env={"DOCKER": str(fake_docker)},
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("compose.transcode.yaml", docker_log.read_text(encoding="utf-8"))

            docker_log.write_text("", encoding="utf-8")
            result_opt_in = run_script(
                f'. "{PROJECT_ROOT / "scripts/lib.sh"}"; run_compose "{env_file}" ps',
                cwd=root,
                env={"DOCKER": str(fake_docker), "RA2_COMPOSE_TRANSCODE": "1"},
            )
            self.assertEqual(result_opt_in.returncode, 0, result_opt_in.stderr)
            self.assertIn(
                "compose.transcode.yaml",
                docker_log.read_text(encoding="utf-8"),
            )

    def test_run_compose_adds_webrtc_overlay_when_enabled(self):
        with temp_workspace() as temp_dir:
            root = Path(temp_dir)
            env_file = root / ".env"
            env_file.write_text("", encoding="utf-8")
            (root / "compose.yaml").write_text("services: {}\n", encoding="utf-8")
            (root / "compose.webrtc.yaml").write_text("services: {}\n", encoding="utf-8")

            fake_docker = root / "docker"
            docker_log = root / "docker.args"
            write_executable(
                fake_docker,
                f"""
                #!/bin/sh
                echo "$@" >> "{docker_log}"
                if [ "$1" = info ]; then exit 0; fi
                exit 0
                """,
            )

            result = run_script(
                f'. "{PROJECT_ROOT / "scripts/lib.sh"}"; run_compose "{env_file}" up -d',
                cwd=root,
                env={"DOCKER": str(fake_docker), "RA2_COMPOSE_WEBRTC": "1"},
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("compose.webrtc.yaml", docker_log.read_text(encoding="utf-8"))

            docker_log.write_text("", encoding="utf-8")
            result_opt_out = run_script(
                f'. "{PROJECT_ROOT / "scripts/lib.sh"}"; run_compose "{env_file}" ps',
                cwd=root,
                env={"DOCKER": str(fake_docker), "RA2_COMPOSE_WEBRTC": "0"},
            )
            self.assertEqual(result_opt_out.returncode, 0, result_opt_out.stderr)
            self.assertNotIn("compose.webrtc.yaml", docker_log.read_text(encoding="utf-8"))

    def test_run_compose_adds_ultra_overlay_when_enabled(self):
        with temp_workspace() as temp_dir:
            root = Path(temp_dir)
            env_file = root / ".env"
            env_file.write_text("", encoding="utf-8")
            (root / "compose.yaml").write_text("services: {}\n", encoding="utf-8")
            (root / "compose.ultra.yaml").write_text("services: {}\n", encoding="utf-8")

            fake_docker = root / "docker"
            docker_log = root / "docker.args"
            write_executable(
                fake_docker,
                f"""
                #!/bin/sh
                echo "$@" >> "{docker_log}"
                if [ "$1" = info ]; then exit 0; fi
                exit 0
                """,
            )

            result = run_script(
                f'. "{PROJECT_ROOT / "scripts/lib.sh"}"; run_compose "{env_file}" up -d',
                cwd=root,
                env={"DOCKER": str(fake_docker), "RA2_COMPOSE_ULTRA": "1"},
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("compose.ultra.yaml", docker_log.read_text(encoding="utf-8"))


class TlsEnsureCheckpointUnitTest(unittest.TestCase):
    def test_generate_tls_certs_is_idempotent_when_material_exists(self):
        if not shutil.which("openssl"):
            self.skipTest("openssl is not installed")

        with temp_workspace() as temp_dir:
            root = Path(temp_dir)
            tls_dir = root / "tls"
            tls_dir.mkdir()
            cert = tls_dir / "cert.pem"
            key = tls_dir / "key.pem"
            cert.write_text("existing-cert", encoding="utf-8")
            key.write_text("existing-key", encoding="utf-8")
            env_file = root / ".env"
            env_file.write_text(
                f"TLS_DIR={tls_dir}\nNAS_HOSTNAME=test.local\nNAS_LAN_IP=127.0.0.1\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                ["sh", str(PROJECT_ROOT / "scripts/generate-tls-certs.sh")],
                cwd=root,
                env={**os.environ, "COMPOSE_DIR": str(root), "ENV_FILE": str(env_file)},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("TLS certificate already exists", result.stdout)
            self.assertEqual(cert.read_text(encoding="utf-8"), "existing-cert")
            self.assertEqual(key.read_text(encoding="utf-8"), "existing-key")

    def test_ensure_tls_generates_and_validates_material(self):
        if not shutil.which("openssl"):
            self.skipTest("openssl is not installed")

        with temp_workspace() as temp_dir:
            root = Path(temp_dir)
            tls_dir = root / "tls"
            env_file = root / ".env"
            env_file.write_text(
                f"TLS_DIR={tls_dir}\nNAS_HOSTNAME=test.local\nNAS_LAN_IP=127.0.0.1\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                ["sh", str(PROJECT_ROOT / "scripts/ensure-tls.sh")],
                cwd=root,
                env={**os.environ, "COMPOSE_DIR": str(root), "ENV_FILE": str(env_file)},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            combined = result.stdout + result.stderr
            if result.returncode != 0 and (
                "uid 1000" in combined or "TLS key is not readable by container user" in combined
            ):
                self.skipTest("ensure-tls could not chown generated certs to uid 1000")

            self.assertEqual(result.returncode, 0, combined)
            self.assertTrue((tls_dir / "cert.pem").is_file())
            self.assertTrue((tls_dir / "key.pem").is_file())
            self.assertIn("[OK] TLS material ready", result.stdout)


class EnvironmentCheckpointUnitTest(unittest.TestCase):
    def test_validate_env_rejects_duplicate_serials(self):
        with temp_workspace() as temp_dir:
            root = Path(temp_dir)
            (root / ".env").write_text(
                "\n".join(
                    [
                        "VNC_PASSWORD=player-secret",
                        "PLAYER1_SERIAL=11112222333344445555",
                        "PLAYER2_SERIAL=11112222333344445555",
                        "PLAYER1_HTTP_PORT=6081",
                        "PLAYER2_HTTP_PORT=6082",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                ["sh", str(PROJECT_ROOT / "scripts/validate-env.sh")],
                cwd=root,
                env={**os.environ, "COMPOSE_DIR": str(root)},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn("PLAYER1_SERIAL and PLAYER2_SERIAL must differ", result.stdout)

    def test_validate_env_rejects_reserved_browser_port(self):
        with temp_workspace() as temp_dir:
            root = Path(temp_dir)
            (root / ".env").write_text(
                "\n".join(
                    [
                        "VNC_PASSWORD=player-secret",
                        "PLAYER1_SERIAL=11112222333344445555",
                        "PLAYER2_SERIAL=55554444333322221111",
                        "PLAYER1_HTTP_PORT=8080",
                        "PLAYER2_HTTP_PORT=6082",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                ["sh", str(PROJECT_ROOT / "scripts/validate-env.sh")],
                cwd=root,
                env={**os.environ, "COMPOSE_DIR": str(root)},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn("must not be 8080", result.stdout)

    def test_validate_env_accepts_customized_identity_and_ports(self):
        with temp_workspace() as temp_dir:
            root = Path(temp_dir)
            (root / ".env").write_text(
                "\n".join(
                    [
                        "VNC_PASSWORD=player-secret",
                        "PLAYER1_SERIAL=10001000100010001000",
                        "PLAYER2_SERIAL=20002000200020002000",
                        "PLAYER1_HTTP_PORT=6081",
                        "PLAYER2_HTTP_PORT=6082",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                ["sh", str(PROJECT_ROOT / "scripts/validate-env.sh")],
                cwd=root,
                env={**os.environ, "COMPOSE_DIR": str(root)},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Environment validation passed.", result.stdout)


class WebsockifyCheckpointUnitTest(unittest.TestCase):
    def test_token_file_routes_vnc_and_audio_targets(self):
        tokens = (PROJECT_ROOT / "container/websockify-tokens.cfg").read_text(encoding="utf-8")
        self.assertIn("vnc: 127.0.0.1:5900", tokens)
        self.assertIn("audio: 127.0.0.1:5711", tokens)
        self.assertIn("latency: 127.0.0.1:5721", tokens)

    def test_start_websockify_enables_tls_args_when_certificates_exist(self):
        with temp_workspace() as temp_dir:
            root = Path(temp_dir)
            cert = root / "cert.pem"
            key = root / "key.pem"
            cert.write_text("cert", encoding="utf-8")
            key.write_text("key", encoding="utf-8")

            novnc_run = root / "opt/novnc/utils/websockify/run"
            novnc_run.parent.mkdir(parents=True)
            run_log = root / "websockify.args"
            write_executable(
                novnc_run,
                f"""
                #!/bin/sh
                echo "$@" > "{run_log}"
                exit 0
                """,
            )

            launcher = root / "start-websockify.sh"
            token_cfg = root / "websockify-tokens.cfg"
            token_cfg.write_text(
                (PROJECT_ROOT / "container/websockify-tokens.cfg").read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            launcher.write_text(
                (PROJECT_ROOT / "container/start-websockify.sh")
                .read_text(encoding="utf-8")
                .replace('RUNNER="/opt/novnc/utils/websockify/run"', f'RUNNER="{root / "opt/novnc/utils/websockify/run"}"')
                .replace('WEB_ROOT="/opt/novnc"', f'WEB_ROOT="{root / "opt/novnc"}"')
                .replace("/opt/ra2/websockify-tokens.cfg", str(token_cfg)),
                encoding="utf-8",
            )
            launcher.chmod(0o755)

            result = run_script(
                f"sh {shlex.quote(str(launcher))}",
                env={"TLS_CERT": str(cert), "TLS_KEY": str(key)},
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            logged = run_log.read_text(encoding="utf-8")
            self.assertIn(f'--cert={cert}', logged)
            self.assertIn(f'--key={key}', logged)
            self.assertIn("--token-plugin TokenFile", logged)


class AudioProxyCheckpointUnitTest(unittest.TestCase):
    def test_audio_proxy_handshake_returns_ready_for_opus(self):
        proc = subprocess.Popen(
            [
                "sh",
                str(PROJECT_ROOT / "container/audio-proxy.sh"),
                "proxy",
                "4711",
                "s16le",
                "44100",
                "2",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            stdout, stderr = proc.communicate(input="CD:opus\nSR:44100\n\n", timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            stdout, stderr = proc.communicate()
            if stderr and "socat not found" in stderr:
                self.skipTest("socat is not installed")
            if stderr and "GStreamer" in stderr:
                self.skipTest("GStreamer is not installed")
            first_line = stdout.splitlines()[0] if stdout else ""
            self.assertEqual(first_line, "READY", stderr)
            return

        if proc.returncode != 0 and stderr and "socat not found" in stderr:
            self.skipTest("socat is not installed")
        if proc.returncode != 0 and stderr and "GStreamer" in stderr:
            self.skipTest("GStreamer is not installed")

        first_line = stdout.splitlines()[0] if stdout else ""
        self.assertEqual(first_line, "READY", stderr)


class BrowserEndpointCheckpointUnitTest(unittest.TestCase):
    def test_healthcheck_uses_http_without_tls_and_https_with_tls(self):
        with temp_workspace() as temp_dir:
            root = Path(temp_dir)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            python_log = root / "python.log"
            fake_python = bin_dir / "python"
            write_executable(
                fake_python,
                f"""
                #!/bin/sh
                printf '%s\\n' "$*" >> "{python_log}"
                exit 0
                """,
            )
            healthcheck = root / "healthcheck-novnc.sh"
            healthcheck.write_text(
                (PROJECT_ROOT / "container/healthcheck-novnc.sh")
                .read_text(encoding="utf-8")
                .replace("  python -c", f"  {shlex.quote(str(fake_python))} -c"),
                encoding="utf-8",
            )
            healthcheck.chmod(0o755)

            cert = root / "cert.pem"
            key = root / "key.pem"
            env = {
                "TLS_CERT": str(cert),
                "TLS_KEY": str(key),
            }

            result_without_tls = run_script(
                f"sh {shlex.quote(str(healthcheck))}",
                env=env,
            )
            self.assertEqual(result_without_tls.returncode, 0, result_without_tls.stderr)
            self.assertIn("http://127.0.0.1:6080/", python_log.read_text(encoding="utf-8"))

            cert.write_text("cert", encoding="utf-8")
            key.write_text("key", encoding="utf-8")
            python_log.write_text("", encoding="utf-8")

            result_with_tls = run_script(
                f"sh {shlex.quote(str(healthcheck))}",
                env=env,
            )
            self.assertEqual(result_with_tls.returncode, 0, result_with_tls.stderr)
            logged = python_log.read_text(encoding="utf-8")
            self.assertIn("https://127.0.0.1:6080/", logged)
            self.assertIn("ssl.create_default_context", logged)


class NasPreflightCheckpointUnitTest(unittest.TestCase):
    def test_preflight_reports_tls_overlay_and_missing_tls_as_warning_not_failure(self):
        with temp_workspace() as temp_dir:
            root = Path(temp_dir) / "ra2-lan-party"
            project = root / "project"
            assets = root / "assets"
            prefixes = root / "prefixes"
            project.mkdir(parents=True)
            assets.mkdir()
            (prefixes / "player1-win32").mkdir(parents=True)
            (prefixes / "player2-win32").mkdir(parents=True)

            for filename in ["compose.yaml", "compose.https.yaml"]:
                (project / filename).write_text("services: {}\n", encoding="utf-8")
            (project / ".env").write_text(
                f"ASSETS_DIR={assets}\nTLS_DIR={root / 'tls'}\n",
                encoding="utf-8",
            )
            (project / "container").mkdir()
            (project / "container/Dockerfile").write_text("FROM scratch\n", encoding="utf-8")

            fake_docker = project / "docker"
            write_executable(
                fake_docker,
                """
                #!/bin/sh
                case "$*" in
                  "compose version") exit 0 ;;
                  *) exit 1 ;;
                esac
                """,
            )

            result = subprocess.run(
                ["sh", str(PROJECT_ROOT / "scripts/preflight-nas.sh")],
                cwd=project,
                env={
                    **os.environ,
                    "PROJECT_ROOT": str(root),
                    "COMPOSE_DIR": str(project),
                    "ASSETS_DIR": str(assets),
                    "DOCKER": str(fake_docker),
                },
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("[OK] HTTPS compose overlay present", result.stdout)
            self.assertIn("[WARN] TLS not generated yet", result.stdout)
            self.assertIn("0 failed", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
