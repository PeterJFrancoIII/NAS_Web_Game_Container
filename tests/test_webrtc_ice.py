"""Unit tests for container/webrtc-media.py ICE candidate handling."""

import importlib.util
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

PROJECT_ROOT = Path(__file__).resolve().parents[1]


def load_webrtc_media(
    *,
    nas_lan_ip: str = "192.168.0.193",
    ice_host: str = "peterjfrancoiii2.synology.me",
    public_ip: str = "108.2.161.76",
):
    env = {
        "NAS_LAN_IP": nas_lan_ip,
        "WEBRTC_ICE_CANDIDATE_HOST": ice_host,
        "NAS_PUBLIC_HOSTNAME": "",
    }
    for key, value in env.items():
        os.environ[key] = value
    for key in list(os.environ):
        if key.startswith("WEBRTC_") and key not in env:
            del os.environ[key]

    module_name = f"webrtc_media_test_{nas_lan_ip.replace('.', '_')}"
    path = PROJECT_ROOT / "container" / "webrtc-media.py"
    spec = importlib.util.spec_from_file_location(module_name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    with patch("socket.gethostbyname", return_value=public_ip):
        spec.loader.exec_module(module)
    return module


SAMPLE_HOST_CANDIDATE = (
    "candidate:842163049 1 udp 2122260223 192.168.0.193 62003 typ host generation 0"
)
SAMPLE_MDNS_CANDIDATE = (
    "candidate:842163049 1 udp 2122260223 abcdef.local 54321 typ host generation 0"
)


class WebRtcMediaIceTest(unittest.TestCase):
    def setUp(self):
        self.wm = load_webrtc_media()

    def test_expand_private_candidate_includes_lan_and_public(self):
        expanded = self.wm._expand_ice_candidates(SAMPLE_HOST_CANDIDATE)
        addresses = {c.split()[4] for c in expanded}
        self.assertIn("192.168.0.193", addresses)
        self.assertIn("108.2.161.76", addresses)
        self.assertEqual(len(expanded), 2)

    def test_rewrite_sdp_duplicates_lan_candidates_in_offer(self):
        sdp = "\r\n".join(
            [
                "v=0",
                "m=video 9 UDP/TLS/RTP/SAVPF 96",
                f"a=candidate:{SAMPLE_HOST_CANDIDATE}",
                "",
            ]
        )
        out = self.wm._rewrite_sdp_ice_candidates(sdp)
        self.assertIn("192.168.0.193", out)
        self.assertIn("108.2.161.76", out)
        self.assertEqual(out.count("a=candidate:"), 2)

    def test_sanitize_client_answer_strips_mdns_host_lines(self):
        sdp = "\r\n".join(
            [
                "v=0",
                f"a=candidate:{SAMPLE_MDNS_CANDIDATE}",
                f"a=candidate:{SAMPLE_HOST_CANDIDATE}",
                "",
            ]
        )
        out = self.wm._sanitize_client_answer_sdp(sdp)
        self.assertNotIn(".local", out)
        self.assertIn("192.168.0.193", out)

    def test_sanitize_client_answer_leaves_zero_candidates_when_only_mdns(self):
        sdp = "\r\n".join(["v=0", f"a=candidate:{SAMPLE_MDNS_CANDIDATE}", ""])
        summary = self.wm._summarize_sdp_ice(self.wm._sanitize_client_answer_sdp(sdp))
        self.assertEqual(summary["candidates"], 0)

    def test_sdp_ice_has_usable_candidates_counts_host(self):
        summary = {"types": {"host": 2}}
        self.assertTrue(self.wm._sdp_ice_has_usable_candidates(summary))

    def test_sdp_ice_has_usable_candidates_rejects_empty(self):
        self.assertFalse(self.wm._sdp_ice_has_usable_candidates({"types": {}}))


if __name__ == "__main__":
    unittest.main()
