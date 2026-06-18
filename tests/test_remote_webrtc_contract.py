"""Remote Player 1 WebRTC contracts — coturn ports, client ICE policy, deploy gates."""

from __future__ import annotations

import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]


def read(relative_path: str) -> str:
    return (PROJECT_ROOT / relative_path).read_text(encoding="utf-8")


def parse_env_example() -> dict[str, str]:
    values: dict[str, str] = {}
    for line in read(".env.example").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        values[key.strip()] = val.strip()
    return values


def parse_turnserver_conf() -> dict[str, int]:
    out: dict[str, int] = {}
    for line in read("coturn/turnserver.conf").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        if key in ("listening-port", "tls-listening-port", "min-port", "max-port"):
            out[key.replace("-", "_")] = int(val)
    return out


def port_ranges_overlap(min_a: int, max_a: int, min_b: int, max_b: int) -> bool:
    return min_a <= max_b and min_b <= max_a


class CoturnPlayer1PortContractTest(unittest.TestCase):
    """Coturn relay must bind on host — player2 docker-proxy on 62021-62040 caused 508 errors."""

    def setUp(self) -> None:
        self.env = parse_env_example()
        self.turn = parse_turnserver_conf()
        self.p1_min = int(self.env.get("PLAYER1_WEBRTC_UDP_MIN", "62001"))
        self.p1_max = int(self.env.get("PLAYER1_WEBRTC_UDP_MAX", "62020"))
        self.p2_min = int(self.env.get("PLAYER2_WEBRTC_UDP_MIN", "62021"))
        self.p2_max = int(self.env.get("PLAYER2_WEBRTC_UDP_MAX", "62040"))
        self.relay_min = self.turn["min_port"]
        self.relay_max = self.turn["max_port"]
        self.turn_listen = self.turn["listening_port"]

    def test_coturn_relay_does_not_overlap_player2_docker_publish(self) -> None:
        self.assertFalse(
            port_ranges_overlap(
                self.relay_min, self.relay_max, self.p2_min, self.p2_max
            ),
            f"coturn relay {self.relay_min}-{self.relay_max} overlaps player2 "
            f"docker-proxy publish {self.p2_min}-{self.p2_max}",
        )

    def test_coturn_relay_within_player1_router_forward_range(self) -> None:
        self.assertGreaterEqual(self.relay_min, self.p1_min)
        self.assertLessEqual(self.relay_max, self.p1_max)

    def test_coturn_listen_port_outside_relay_range(self) -> None:
        self.assertFalse(
            self.relay_min <= self.turn_listen <= self.relay_max,
            f"TURN listen {self.turn_listen} must not be inside relay "
            f"{self.relay_min}-{self.relay_max}",
        )

    def test_coturn_turn_listen_is_player1_turn_port(self) -> None:
        self.assertEqual(self.turn_listen, 62011)

    def test_player1_video_ports_do_not_include_player2_range(self) -> None:
        video_max = int(self.env.get("PLAYER1_WEBRTC_VIDEO_UDP_MAX", "62010"))
        self.assertLess(video_max, self.p2_min)


class UltraPlayRemoteIceContractTest(unittest.TestCase):
    """Lock remote Player 1 ICE: direct first, relay retry on failure — not relay-first on DDNS."""

    def setUp(self) -> None:
        self.ultra_js = read("container/remote-ultra/ultra-play.js")
        self.ice_utils = read("container/remote-ultra/webrtc-ice-utils.js")

    def test_no_remote_relay_first_flag_in_client(self) -> None:
        self.assertNotIn("webrtcPreferRelayIce", self.ultra_js)

    def test_remote_prefers_turn_order_not_relay_only(self) -> None:
        self.assertIn("preferRelayOnRemote: false", self.ultra_js)
        self.assertIn("orderIceServersForRemote", self.ultra_js)
        self.assertIn("allocating TURN relay", self.ultra_js)

    def test_relay_policy_delegates_to_ice_utils(self) -> None:
        self.assertIn("Ice.shouldUseRelayIcePolicy", self.ultra_js)
        self.assertIn("function shouldUseRelayIcePolicy(opts = {})", self.ice_utils)
        self.assertIn("preferRelayOnRemote", self.ice_utils)

    def test_early_trickle_answer_before_long_ice_gather(self) -> None:
        self.assertIn("earlyTrickle: true", self.ultra_js)
        self.assertIn("answer sent — trickling ICE", self.ultra_js)
        self.assertIn("completeIceTrickleAfterAnswer", self.ultra_js)

    def test_remote_waits_for_gathered_ice_not_sdp_only(self) -> None:
        self.assertIn("waitForRemoteRelayCandidate", self.ultra_js)
        self.assertIn("remotePlayIceServers", self.ultra_js)
        self.assertIn("RTCPeerConnection remote TURN relay", self.ultra_js)
        self.assertIn("turnServersForRemotePlay", self.ultra_js)
        self.assertIn("gathering ICE for answer", self.ultra_js)
        self.assertIn("REMOTE_ICE_ANSWER_DEADLINE_MS", self.ultra_js)
        self.assertNotIn("setTimeout(resolve, 600)", self.ultra_js)
        self.assertIn("client ICE → server", self.ultra_js)

    def test_remote_udp_verification_requires_sustained_rtp(self) -> None:
        self.assertIn("Ice.isUdpMediaVerified", self.ultra_js)
        self.assertIn("function isUdpMediaVerified", self.ice_utils)
        self.assertIn("REMOTE_WEBRTC_DISCONNECT_GRACE_MS", self.ultra_js)
        self.assertIn("shouldFallbackOnConnectionDisconnect", self.ice_utils)
        self.assertIn("Ice.shouldSendEndOfCandidates", self.ultra_js)
        self.assertIn("refusing empty end-of-candidates", self.ultra_js)
        self.assertIn("trickle timeout", self.ultra_js)
        self.assertIn("flushUsableIceTrickle", self.ultra_js)

    def test_remote_trickle_loop_non_blocking(self) -> None:
        self.assertIn("startWebRtcTrickleLoop", self.ultra_js)
        self.assertIn("remoteIceTrickleInProgress", self.ultra_js)
        self.assertIn("REMOTE_ICE_TRICKLE_TIMEOUT_MS", self.ultra_js)
        self.assertIn("answer sent — trickling ICE", self.ultra_js)

    def test_relay_peer_connection_requires_turn_credentials(self) -> None:
        self.assertIn("RTCPeerConnection relay-only", self.ultra_js)
        self.assertIn("TURN servers with credentials required for remote relay ICE", self.ultra_js)

    def test_remote_relay_retry_wired(self) -> None:
        self.assertIn("Ice.shouldAttemptRemoteRelayRetry", self.ultra_js)
        self.assertIn("connectWebRtcVideo({ relayRetry: true })", self.ultra_js)
        self.assertIn("remote play — ICE", self.ultra_js)
        self.assertIn("preserveConnectPromise", self.ultra_js)
        self.assertIn("webrtcUdpAbandoned", self.ultra_js)
        self.assertIn("signalingSocketBusy", self.ultra_js)
        self.assertIn("webrtcConnectPromise = null", self.ultra_js)

    def test_signaling_errors_skip_relay_retry(self) -> None:
        self.assertIn('allowRelayRetry: false', self.ultra_js)
        self.assertIn("UDP signaling failed", self.ultra_js)
        self.assertIn("fallbackReasonAllowsRelayRetry(detail)", self.ultra_js)
        self.assertIn("resetWebRtcPeerForRelayRetry", self.ultra_js)

    def test_same_origin_webrtc_signal_for_remote(self) -> None:
        self.assertIn("/webrtc-signal", self.ultra_js)
        self.assertIn("location.host", self.ultra_js)

    def test_webrtc_tests_gate_redeploy(self) -> None:
        redeploy = read("scripts/redeploy-ultra.sh")
        deploy_tests = read("scripts/run-deploy-tests.sh")
        self.assertIn("run-deploy-tests.sh", redeploy)
        self.assertIn("run-webrtc-tests.sh", deploy_tests)

    def test_remote_turn_probe_script_exists(self) -> None:
        probe = PROJECT_ROOT / "scripts" / "probe-webrtc-turn-remote.sh"
        self.assertTrue(probe.is_file())
        content = probe.read_text(encoding="utf-8")
        self.assertIn("turn-ice.json", content)
        self.assertIn("5349", content)


class WebRtcMediaRemoteOfferContractTest(unittest.TestCase):
    """Server must advertise LAN + public ICE for Player 1 remote direct UDP."""

    def test_webrtc_media_expands_private_candidates(self) -> None:
        media = read("container/webrtc-media.py")
        self.assertIn("_ice_advertise_hosts", media)
        self.assertIn("NAS_LAN_IP", media)
        self.assertIn("_public_ice_host", media)
        self.assertIn("replacing stale signaling client", media)
        self.assertIn("reuse_helper", media)

    def test_gateway_proxies_webrtc_signal_on_play_port(self) -> None:
        gateway = read("container/ra2-stream-gateway.py")
        self.assertIn('path == "/webrtc-signal"', gateway)
        self.assertIn("webrtc_signal_proxy", gateway)
        self.assertIn("/turn-ice.json", gateway)


if __name__ == "__main__":
    unittest.main()
