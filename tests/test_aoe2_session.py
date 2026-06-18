"""AoE II session prep tests — CD bypass, registry, and work-dir layout."""

import json
import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
PREPARE_SCRIPT = PROJECT_ROOT / "container" / "prepare-aoe2-session.sh"

CRACKED_EMPIRES2_SIZE = 2_596_864
CRACKED_AGE2_X1_SIZE = 2_695_213
RETAIL_AGE2_X1_SIZE = 341_279


def read(relative_path):
    return (PROJECT_ROOT / relative_path).read_text(encoding="utf-8")


def temp_workspace():
    # Avoid ':' in PATH entries (e.g. Red_Alert2_NAS:Arch breaks PATH parsing on Unix).
    return tempfile.TemporaryDirectory(dir="/tmp", prefix="ra2-aoe2-test-")


def write_bytes(path, size, marker):
    path.parent.mkdir(parents=True, exist_ok=True)
    chunk = (marker * ((size // len(marker)) + 1))[:size]
    path.write_bytes(chunk.encode("ascii"))


def write_executable(path, content):
    path.write_text(textwrap.dedent(content).lstrip(), encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class Aoe2PrepareScriptContractTest(unittest.TestCase):
    def setUp(self):
        self.prepare = read("container/prepare-aoe2-session.sh")
        self.games = json.loads(read("config/games.json"))

    def test_cdpath_defaults_to_install_dir_not_disc_drives(self):
        self.assertIn("AOE2_CD_PATH:-C:", self.prepare)
        self.assertIn("AOE2_AOC_CD_PATH:-C:", self.prepare)
        self.assertIn("age2_x1", self.prepare)
        self.assertNotIn('AOE2_CD_PATH:-D:', self.prepare)
        self.assertIn("CDPath to point at the install tree, not D:/E:", self.prepare)

    def test_conquerors_install_registry_keys_are_written(self):
        self.assertIn("InstalledGroup /t REG_SZ /d \"3\"", self.prepare)
        self.assertIn("VersionType /t REG_SZ /d \"RetailVersion\"", self.prepare)
        self.assertIn("CDPathAge2 /t REG_SZ /d \"$aoc_cd\"", self.prepare)
        self.assertIn("Conquerors Expansion", self.prepare)

    def test_wine_cdrom_drive_types_registered(self):
        self.assertIn("register_wine_cdrom_drives", self.prepare)
        self.assertIn('/v "d:" /t REG_SZ /d "cdrom"', self.prepare)
        self.assertIn('/v "e:" /t REG_SZ /d "cdrom"', self.prepare)

    def test_conquerors_data_and_age2_x1_materialization_present(self):
        self.assertIn("ensure_conquerors_data", self.prepare)
        self.assertIn("materialize_age2_x1_workdir", self.prepare)
        self.assertIn("empires2_x1_p1.dat", self.prepare)
        self.assertIn("rebuilt stale age2_x1 work dir", self.prepare)

    def test_games_profile_launches_from_install_not_assets(self):
        profile = self.games["aoe2"]
        self.assertNotIn("wineLaunchCwdEnv", profile)
        self.assertEqual(profile["wineExePath"], "C:\\AOE2\\EMPIRES2.EXE")
        self.assertTrue(profile["writableWorkDir"])

    def test_userpatch_disabled_by_default(self):
        self.assertIn('ENABLE_USERPATCH="${AOE2_ENABLE_USERPATCH:-0}"', self.prepare)


class Aoe2PrepareIntegrationTest(unittest.TestCase):
    def _run_prepare(self, root):
        bin_dir = root / "bin"
        bin_dir.mkdir()
        reg_log = root / "wine-reg.log"
        reg_log.touch()
        wineprefix = root / "wineprefix"
        wineprefix.mkdir()

        write_executable(
            bin_dir / "wine",
            """
            #!/bin/sh
            case "$1" in
              reg) echo "$*" >> "$WINE_REG_LOG" ;;
            esac
            exit 0
            """,
        )
        write_executable(
            bin_dir / "wineserver",
            """
            #!/bin/sh
            exit 0
            """,
        )

        assets = root / "assets"
        stage = root / "staging"
        patch_dir = root / "patches"
        patch_data = root / "10c-data"
        game_dir = root / "game-work"

        write_bytes(assets / "EMPIRES2.EXE", CRACKED_EMPIRES2_SIZE, "E2")
        write_bytes(assets / "AGE2_X1.EXE", CRACKED_AGE2_X1_SIZE, "X1")
        (assets / "Data").mkdir()
        (assets / "Data" / "placeholder.dat").write_bytes(b"x")

        write_bytes(patch_dir / "empires2.exe", CRACKED_EMPIRES2_SIZE, "E2")
        write_bytes(stage / "aok_cd" / "CLCD16.DLL", 1024, "C")
        write_bytes(stage / "aok_cd" / "CLCD32.DLL", 1024, "C")
        write_bytes(stage / "aok_cd" / "GAME" / "EMPIRES2.EXE", 280_000, "R")
        write_bytes(stage / "aoc_cd" / "CRACK" / "AGE2_X1.EXE", CRACKED_AGE2_X1_SIZE, "X1")
        write_bytes(stage / "aoc_cd" / "GAME" / "AGE2_X1" / "AGE2_X1.EXE", 280_000, "R")

        write_bytes(patch_data / "empires2_x1_p1.dat", 4096, "D")
        write_bytes(patch_data / "gamedata_x1_p1.drs", 4096, "D")
        write_bytes(patch_data / "age2_x1_10c.exe", RETAIL_AGE2_X1_SIZE, "R")

        # Simulate stale retail Conquerors exe left by an old UserPatch attempt.
        stale_dir = game_dir / "age2_x1"
        stale_dir.mkdir(parents=True)
        write_bytes(stale_dir / "age2_x1.exe", RETAIL_AGE2_X1_SIZE, "R")

        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{bin_dir}:/usr/bin:/bin",
                "WINEPREFIX": str(wineprefix),
                "WINE_REG_LOG": str(reg_log),
                "AOE2_ASSETS_DIR": str(assets),
                "AOE2_STAGE": str(stage),
                "AOE2_PATCH_DIR": str(patch_dir),
                "AOE2_10C_DATA_DIR": str(patch_data),
                "AOE2_ENABLE_USERPATCH": "0",
                "AOE2_USE_CNC_DDRAW": "0",
            }
        )

        result = subprocess.run(
            ["/bin/sh", str(PREPARE_SCRIPT), str(game_dir)],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        self.assertEqual(
            result.returncode,
            0,
            msg=f"prepare-aoe2-session.sh failed:\n{result.stdout}",
        )
        return game_dir, reg_log.read_text(encoding="utf-8"), result.stdout

    def test_prepare_materializes_cracked_exes_and_conquerors_data(self):
        with temp_workspace() as temp_dir:
            game_dir, reg_log, output = self._run_prepare(Path(temp_dir))

            empires2 = game_dir / "EMPIRES2.EXE"
            age2_x1 = game_dir / "age2_x1" / "age2_x1.exe"
            age2_x1_upper = game_dir / "age2_x1" / "AGE2_X1.EXE"
            dat_file = game_dir / "Data" / "empires2_x1_p1.dat"
            d_mirror = game_dir / ".cd-mounts" / "aok" / "GAME" / "EMPIRES2.EXE"
            e_mirror = game_dir / ".cd-mounts" / "aoc" / "GAME" / "AGE2_X1" / "AGE2_X1.EXE"

            self.assertTrue(empires2.is_file())
            self.assertEqual(empires2.stat().st_size, CRACKED_EMPIRES2_SIZE)
            self.assertTrue(age2_x1.is_file())
            self.assertGreaterEqual(age2_x1.stat().st_size, 1_000_000)
            self.assertTrue(age2_x1_upper.is_file())
            self.assertEqual(age2_x1.stat().st_size, age2_x1_upper.stat().st_size)
            self.assertTrue(dat_file.is_file())
            self.assertEqual(d_mirror.stat().st_size, CRACKED_EMPIRES2_SIZE)
            self.assertEqual(e_mirror.stat().st_size, CRACKED_AGE2_X1_SIZE)
            self.assertIn("rebuilt stale age2_x1 work dir", output)
            self.assertIn("Conquerors 1.0c data present in Data/", output)

    def test_prepare_registers_install_cdpaths_and_cdrom_drives(self):
        with temp_workspace() as temp_dir:
            _game_dir, reg_log, output = self._run_prepare(Path(temp_dir))

            self.assertIn("InstalledGroup /t REG_SZ /d 3", reg_log)
            self.assertIn("CDPath", reg_log)
            self.assertIn("cdrom", reg_log)
            self.assertIn("Conquerors InstalledGroup=3", output)
            self.assertIn("Wine D: and E: registered as cdrom drives", output)

    def test_cd_mirror_does_not_ship_opengl_icd_stubs(self):
        with temp_workspace() as temp_dir:
            game_dir, _reg_log, _output = self._run_prepare(Path(temp_dir))
            icd_files = list(game_dir.rglob("*.icd")) + list(game_dir.rglob("*.ICD"))
            self.assertEqual(icd_files, [])


class Aoe2DeployVerifyScriptContractTest(unittest.TestCase):
    def test_verify_script_exists_and_checks_invariants(self):
        script = read("scripts/verify-aoe2-session.sh")
        self.assertIn("prepare-aoe2-session.sh", script)
        self.assertIn("InstalledGroup", script)
        self.assertIn("register_wine_cdrom_drives", script)
        self.assertIn("AOE2_CD_PATH:-C:", script)
        self.assertIn("WINEPREFIX}/drive_c", script)
        self.assertIn("wineLaunchCwdEnv", script)


if __name__ == "__main__":
    unittest.main(verbosity=2)
