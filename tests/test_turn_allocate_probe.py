"""Unit tests for the dependency-free TURN Allocate probe wire encoding.

These lock the fiddly STUN/TURN byte format so a regression in the probe is
caught before it silently reports false negatives against live coturn.
"""

import hashlib
import hmac
import importlib.util
import struct
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]


def load_probe():
    path = PROJECT_ROOT / "scripts" / "turn_allocate_probe.py"
    spec = importlib.util.spec_from_file_location("turn_allocate_probe", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


probe = load_probe()


class TurnAllocateProbeTest(unittest.TestCase):
    def test_attr_pads_to_four_bytes(self):
        # 5-byte value -> 4-byte type/len header + 5 value + 3 pad = 12 bytes.
        attr = probe._attr(0x0006, b"ra2tu")
        self.assertEqual(len(attr), 12)
        attr_type, attr_len = struct.unpack("!HH", attr[0:4])
        self.assertEqual(attr_type, 0x0006)
        self.assertEqual(attr_len, 5)  # length is the unpadded value length
        self.assertEqual(attr[4:9], b"ra2tu")
        self.assertEqual(attr[9:12], b"\x00\x00\x00")

    def test_unauthenticated_allocate_request_shape(self):
        txn = b"\x00" * 12
        msg = probe._message(txn, [probe._attr(probe.ATTR_REQUESTED_TRANSPORT, probe.REQUESTED_TRANSPORT_UDP)])
        msg_type, length = struct.unpack("!HH", msg[0:4])
        cookie = struct.unpack("!I", msg[4:8])[0]
        self.assertEqual(msg_type, probe.ALLOCATE_REQUEST)
        self.assertEqual(cookie, probe.MAGIC_COOKIE)
        self.assertEqual(length, len(msg) - 20)
        parsed_type, attrs = probe._parse(msg)
        self.assertEqual(parsed_type, probe.ALLOCATE_REQUEST)
        self.assertIn(probe.ATTR_REQUESTED_TRANSPORT, attrs)
        # protocol byte 17 (UDP) for the relayed transport
        self.assertEqual(attrs[probe.ATTR_REQUESTED_TRANSPORT][0], 17)

    def test_message_integrity_uses_inflated_length_and_valid_hmac(self):
        txn = b"\x11" * 12
        user, realm, password = "ra2turn", "ra2.lan.party", "secret"
        key = probe._integrity_key(user, realm, password)
        attrs = [
            probe._attr(probe.ATTR_REQUESTED_TRANSPORT, probe.REQUESTED_TRANSPORT_UDP),
            probe._attr(probe.ATTR_USERNAME, user.encode()),
            probe._attr(probe.ATTR_REALM, realm.encode()),
            probe._attr(probe.ATTR_NONCE, b"nonce-value"),
        ]
        body = b"".join(attrs)
        msg = probe._message(txn, attrs, key=key)

        # Final MESSAGE-INTEGRITY attribute is appended (type 0x0008, 20-byte HMAC).
        mi = msg[-24:]
        mi_type, mi_len = struct.unpack("!HH", mi[0:4])
        self.assertEqual(mi_type, probe.ATTR_MESSAGE_INTEGRITY)
        self.assertEqual(mi_len, 20)

        # HMAC must be computed over a header whose length covers body + the
        # 24-byte MESSAGE-INTEGRITY attribute (RFC 5389 §15.4).
        header_for_hmac = struct.pack("!HHI", probe.ALLOCATE_REQUEST, len(body) + 24, probe.MAGIC_COOKIE) + txn
        expected = hmac.new(key, header_for_hmac + body, hashlib.sha1).digest()
        self.assertEqual(mi[4:24], expected)

        # The final on-the-wire header length is the full message length.
        final_len = struct.unpack("!H", msg[2:4])[0]
        self.assertEqual(final_len, len(msg) - 20)

    def test_integrity_key_matches_md5(self):
        key = probe._integrity_key("ra2turn", "ra2.lan.party", "secret")
        self.assertEqual(key, hashlib.md5(b"ra2turn:ra2.lan.party:secret").digest())

    def test_parse_xor_relayed_ipv4(self):
        # 108.2.161.76:62017 XOR-encoded with the magic cookie.
        value = bytes([0x00, 0x01, 0xD3, 0x53, 0x4D, 0x10, 0x05, 0x0E])
        self.assertEqual(probe._parse_xor_relayed(value), "108.2.161.76:62017")

    def test_parse_error_code(self):
        value = b"\x00\x00\x04\x01Unauthorized"
        code, reason = probe._parse_error(value)
        self.assertEqual(code, 401)
        self.assertEqual(reason, "Unauthorized")

    def test_parse_roundtrip_with_multiple_attrs(self):
        txn = b"\x22" * 12
        msg = probe._message(
            txn,
            [
                probe._attr(probe.ATTR_REALM, b"ra2.lan.party"),
                probe._attr(probe.ATTR_NONCE, b"abc"),
            ],
        )
        _, attrs = probe._parse(msg)
        self.assertEqual(attrs[probe.ATTR_REALM], b"ra2.lan.party")
        self.assertEqual(attrs[probe.ATTR_NONCE], b"abc")


if __name__ == "__main__":
    unittest.main()
