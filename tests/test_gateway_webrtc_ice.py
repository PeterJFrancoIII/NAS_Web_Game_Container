"""Unit tests for ra2-stream-gateway WebRTC ICE server config."""

import importlib.util
import json
import os
import sys
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]


def load_gateway(*, video_udp: bool = True, turns_enabled: bool = False):
    os.environ["ULTRA_VIDEO_UDP"] = "1" if video_udp else "0"
    os.environ["WEBRTC_TURN_URLS"] = (
        "turn:peterjfrancoiii2.synology.me:62011?transport=udp,"
        "turn:peterjfrancoiii2.synology.me:62011?transport=tcp"
    )
    os.environ["WEBRTC_TURN_USERNAME"] = "ra2turn"
    os.environ["WEBRTC_TURN_PASSWORD"] = "test-pass"
    os.environ["WEBRTC_ICE_CANDIDATE_HOST"] = "peterjfrancoiii2.synology.me"
    os.environ["WEBRTC_TURNS_PORT"] = "5349"
    os.environ["WEBRTC_TURNS_ENABLED"] = "1" if turns_enabled else "0"

    module_name = f"ra2_stream_gateway_test_{int(turns_enabled)}"
    path = PROJECT_ROOT / "container" / "ra2-stream-gateway.py"
    spec = importlib.util.spec_from_file_location(module_name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


class GatewayWebRtcIceTest(unittest.TestCase):
    def setUp(self):
        self.gw = load_gateway()

    def test_webrtc_ice_servers_include_stun_and_turn(self):
        servers = self.gw._webrtc_ice_servers()
        urls = [s.get("urls") for s in servers]
        self.assertTrue(any(str(u).startswith("stun:") for u in urls))
        self.assertTrue(any(str(u).startswith("turn:") for u in urls))
        self.assertFalse(any(str(u).startswith("turns:") for u in urls))

    def test_turns_included_when_enabled(self):
        gw = load_gateway(turns_enabled=True)
        urls = [s.get("urls") for s in gw._webrtc_ice_servers()]
        self.assertTrue(any(str(u).startswith("turns:") for u in urls))

    def test_turn_entries_have_static_credentials(self):
        servers = self.gw._webrtc_ice_servers()
        turn = [s for s in servers if str(s.get("urls", "")).startswith("turn")]
        self.assertGreaterEqual(len(turn), 2)
        for entry in turn:
            self.assertEqual(entry.get("username"), "ra2turn")
            self.assertEqual(entry.get("credential"), "test-pass")

    def test_turn_ice_json_payload_shape(self):
        payload = json.loads(
            json.dumps({"iceServers": self.gw._webrtc_ice_servers()})
        )
        self.assertIn("iceServers", payload)
        self.assertGreaterEqual(len(payload["iceServers"]), 5)


if __name__ == "__main__":
    unittest.main()
