#!/usr/bin/env python3
"""Dependency-free TURN Allocate probe (long-term credentials), UDP or TCP.

Confirms that a coturn relay allocation actually succeeds from wherever this
runs (e.g. a Mac with a client VPN active, simulating remote play). This is a
stronger check than `nc`, which only proves the port accepts a connection — it
performs the real STUN/TURN Allocate handshake the browser would and verifies a
relayed transport address comes back.

Exit code 0 on a successful relay allocation, non-zero otherwise.

Usage:
  turn_allocate_probe.py HOST PORT USER PASS [udp|tcp]
"""
from __future__ import annotations

import hashlib
import hmac
import secrets
import socket
import struct
import sys

MAGIC_COOKIE = 0x2112A442
ALLOCATE_REQUEST = 0x0003
ALLOCATE_SUCCESS = 0x0103
ALLOCATE_ERROR = 0x0113

ATTR_ERROR_CODE = 0x0009
ATTR_REALM = 0x0014
ATTR_NONCE = 0x0015
ATTR_XOR_RELAYED_ADDRESS = 0x0016
ATTR_REQUESTED_TRANSPORT = 0x0019
ATTR_USERNAME = 0x0006
ATTR_MESSAGE_INTEGRITY = 0x0008

# RFC 5766: REQUESTED-TRANSPORT protocol 17 (UDP) for the relayed transport.
REQUESTED_TRANSPORT_UDP = b"\x11\x00\x00\x00"


def _pad(value: bytes) -> bytes:
    if len(value) % 4:
        value += b"\x00" * (4 - len(value) % 4)
    return value


def _attr(attr_type: int, value: bytes) -> bytes:
    return struct.pack("!HH", attr_type, len(value)) + _pad(value)


def _integrity_key(user: str, realm: str, password: str) -> bytes:
    return hashlib.md5(f"{user}:{realm}:{password}".encode("utf-8")).digest()


def _message(txn: bytes, attrs: list[bytes], key: bytes | None = None) -> bytes:
    body = b"".join(attrs)
    if key is not None:
        # The header length used for MESSAGE-INTEGRITY must include the 24-byte
        # MESSAGE-INTEGRITY attribute that is about to be appended.
        header = struct.pack("!HHI", ALLOCATE_REQUEST, len(body) + 24, MAGIC_COOKIE) + txn
        digest = hmac.new(key, header + body, hashlib.sha1).digest()
        body += _attr(ATTR_MESSAGE_INTEGRITY, digest)
    header = struct.pack("!HHI", ALLOCATE_REQUEST, len(body), MAGIC_COOKIE) + txn
    return header + body


def _parse(data: bytes) -> tuple[int, dict[int, bytes]]:
    if len(data) < 20:
        raise ValueError("short STUN message")
    msg_type, msg_len = struct.unpack("!HH", data[0:4])
    attrs: dict[int, bytes] = {}
    offset = 20
    end = min(20 + msg_len, len(data))
    while offset + 4 <= end:
        attr_type, attr_len = struct.unpack("!HH", data[offset : offset + 4])
        value = data[offset + 4 : offset + 4 + attr_len]
        attrs.setdefault(attr_type, value)
        offset += 4 + attr_len
        if attr_len % 4:
            offset += 4 - attr_len % 4
    return msg_type, attrs


def _parse_error(value: bytes) -> tuple[int, str]:
    if len(value) < 4:
        return 0, ""
    code = value[2] * 100 + value[3]
    return code, value[4:].decode("utf-8", errors="replace")


def _parse_xor_relayed(value: bytes) -> str:
    family = value[1]
    port = struct.unpack("!H", value[2:4])[0] ^ (MAGIC_COOKIE >> 16)
    if family == 0x01:
        addr = struct.unpack("!I", value[4:8])[0] ^ MAGIC_COOKIE
        ip = socket.inet_ntoa(struct.pack("!I", addr))
        return f"{ip}:{port}"
    # IPv6
    cookie6 = struct.pack("!I", MAGIC_COOKIE) + value[8:20] if len(value) >= 20 else b""
    raw = bytes(a ^ b for a, b in zip(value[4:20], cookie6)) if cookie6 else value[4:20]
    return f"[{socket.inet_ntop(socket.AF_INET6, raw)}]:{port}"


def _open(host: str, port: int, transport: str, timeout: float) -> socket.socket:
    if transport == "tcp":
        sock = socket.create_connection((host, port), timeout=timeout)
        sock.settimeout(timeout)
        return sock
    family = socket.AF_INET
    infos = socket.getaddrinfo(host, port, type=socket.SOCK_DGRAM)
    if infos:
        family = infos[0][0]
    sock = socket.socket(family, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    sock.connect((host, port))
    return sock


def _send_recv(sock: socket.socket, transport: str, payload: bytes) -> bytes:
    sock.sendall(payload)
    if transport == "tcp":
        return sock.recv(2048)
    return sock.recv(2048)


def allocate(host: str, port: int, user: str, password: str, transport: str, timeout: float = 5.0) -> int:
    transport = transport.lower()
    label = f"{transport.upper()} {host}:{port}"
    # The challenge/response must share one connection (UDP 5-tuple / TCP socket);
    # coturn binds the nonce to it, so a second socket yields 438 Wrong nonce.
    try:
        sock = _open(host, port, transport, timeout)
    except Exception as exc:  # noqa: BLE001
        print(f"[turn-probe] FAIL {label}: connect failed ({exc})")
        return 2

    try:
        txn = secrets.token_bytes(12)
        first = _message(txn, [_attr(ATTR_REQUESTED_TRANSPORT, REQUESTED_TRANSPORT_UDP)])
        try:
            resp = _send_recv(sock, transport, first)
        except Exception as exc:  # noqa: BLE001
            print(f"[turn-probe] FAIL {label}: no response to Allocate ({exc})")
            return 2

        msg_type, attrs = _parse(resp)
        if msg_type == ALLOCATE_SUCCESS and ATTR_XOR_RELAYED_ADDRESS in attrs:
            relay = _parse_xor_relayed(attrs[ATTR_XOR_RELAYED_ADDRESS])
            print(f"[turn-probe] OK   {label}: relay {relay} (unauthenticated?!)")
            return 0
        if ATTR_REALM not in attrs or ATTR_NONCE not in attrs:
            code, reason = _parse_error(attrs.get(ATTR_ERROR_CODE, b""))
            print(f"[turn-probe] FAIL {label}: no realm/nonce challenge (error {code} {reason})")
            return 3

        realm = attrs[ATTR_REALM].decode("utf-8", errors="replace")
        nonce = attrs[ATTR_NONCE]
        key = _integrity_key(user, realm, password)

        # Up to 2 attempts so a single 438 Stale Nonce can refresh and retry.
        for _ in range(2):
            txn2 = secrets.token_bytes(12)
            authed = _message(
                txn2,
                [
                    _attr(ATTR_REQUESTED_TRANSPORT, REQUESTED_TRANSPORT_UDP),
                    _attr(ATTR_USERNAME, user.encode("utf-8")),
                    _attr(ATTR_REALM, realm.encode("utf-8")),
                    _attr(ATTR_NONCE, nonce),
                ],
                key=key,
            )
            try:
                resp2 = _send_recv(sock, transport, authed)
            except Exception as exc:  # noqa: BLE001
                print(f"[turn-probe] FAIL {label}: no response to authenticated Allocate ({exc})")
                return 4

            msg_type, attrs = _parse(resp2)
            if msg_type == ALLOCATE_SUCCESS and ATTR_XOR_RELAYED_ADDRESS in attrs:
                relay = _parse_xor_relayed(attrs[ATTR_XOR_RELAYED_ADDRESS])
                print(f"[turn-probe] OK   {label}: allocated relay {relay} (user={user}, realm={realm})")
                return 0
            code, reason = _parse_error(attrs.get(ATTR_ERROR_CODE, b""))
            if code == 438 and ATTR_NONCE in attrs:
                nonce = attrs[ATTR_NONCE]
                continue
            print(f"[turn-probe] FAIL {label}: Allocate rejected (error {code} {reason}, realm={realm})")
            return 5
        print(f"[turn-probe] FAIL {label}: stale nonce loop (realm={realm})")
        return 5
    finally:
        sock.close()


def main(argv: list[str]) -> int:
    if len(argv) < 5:
        print(__doc__)
        return 64
    host = argv[1]
    port = int(argv[2])
    user = argv[3]
    password = argv[4]
    transport = argv[5] if len(argv) > 5 else "udp"
    return allocate(host, port, user, password, transport)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
