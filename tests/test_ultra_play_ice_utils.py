"""Runs node unit tests for container/remote-ultra/webrtc-ice-utils.js."""

import shutil
import subprocess
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]


class UltraPlayIceUtilsNodeTest(unittest.TestCase):
    def test_node_ice_utils_suite_passes(self):
        node = shutil.which("node")
        if not node:
            self.skipTest("node not installed")
        script = PROJECT_ROOT / "tests" / "ultra_play_ice_utils.test.mjs"
        proc = subprocess.run(
            [node, "--test", str(script)],
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(
            proc.returncode,
            0,
            msg=f"node --test failed\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}",
        )


if __name__ == "__main__":
    unittest.main()
