#!/usr/bin/env python3
"""Minimal /dev/uinput virtual keyboard/mouse backend (stdlib only)."""

from __future__ import annotations

import ctypes
import ctypes.util
import errno
import os
import struct
import time
from typing import Optional

EV_SYN = 0x00
EV_KEY = 0x01
EV_REL = 0x02
SYN_REPORT = 0x00
BTN_LEFT = 0x110
BTN_RIGHT = 0x111
BTN_MIDDLE = 0x112
REL_X = 0x00
REL_Y = 0x01
REL_WHEEL = 0x08

UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_RELBIT = 0x40045566
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502

KEY_MAP = {
    "space": 57,
    "Up": 103,
    "Down": 108,
    "Left": 105,
    "Right": 106,
    "Return": 28,
    "Enter": 28,
    "Escape": 1,
    "BackSpace": 14,
    "Tab": 15,
    "Shift_L": 42,
    "Shift_R": 54,
    "Control_L": 29,
    "Control_R": 97,
    "Alt_L": 56,
    "Alt_R": 100,
}


class UinputBackend:
    def __init__(self, device_path: str, width: int, height: int, name: str = "ra2-remote-input") -> None:
        self.device_path = device_path
        self.width = max(1, width)
        self.height = max(1, height)
        self.name = name
        self._fd: Optional[int] = None
        self._ioctl = None
        self._pressed_keys: set[int] = set()
        self._last_x: Optional[int] = None
        self._last_y: Optional[int] = None

    @staticmethod
    def available(device_path: str) -> bool:
        return os.path.exists(device_path) and os.access(device_path, os.W_OK | os.R_OK)

    def open(self) -> None:
        if self._fd is not None:
            return
        libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
        fd = os.open(self.device_path, os.O_WRONLY | os.O_NONBLOCK)
        self._fd = fd
        self._ioctl = libc.ioctl
        self._ioctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_void_p]
        self._ioctl.restype = ctypes.c_int

        def _set_bit(cmd: int, bit: int) -> None:
            arr = (ctypes.c_uint8 * 32)()
            arr[bit // 8] = 1 << (bit % 8)
            if self._ioctl(fd, cmd, arr) < 0:
                err = ctypes.get_errno()
                raise OSError(err, os.strerror(err))

        _set_bit(UI_SET_EVBIT, EV_KEY)
        _set_bit(UI_SET_EVBIT, EV_REL)
        _set_bit(UI_SET_EVBIT, EV_SYN)
        _set_bit(UI_SET_RELBIT, REL_X)
        _set_bit(UI_SET_RELBIT, REL_Y)
        _set_bit(UI_SET_RELBIT, REL_WHEEL)
        _set_bit(UI_SET_KEYBIT, BTN_LEFT)
        _set_bit(UI_SET_KEYBIT, BTN_RIGHT)
        _set_bit(UI_SET_KEYBIT, BTN_MIDDLE)
        for code in range(1, 256):
            _set_bit(UI_SET_KEYBIT, code)

        uinput_user_dev = struct.pack(
            "128s64s64s1024s8H",
            self.name.encode()[:127],
            b"RA2 Remote",
            b"RA2 Remote",
            b"",
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
        )
        os.write(fd, uinput_user_dev)
        if self._ioctl(fd, UI_DEV_CREATE, None) < 0:
            err = ctypes.get_errno()
            raise OSError(err, os.strerror(err))
        print(f"[input] uinput device created ({self.name})", flush=True)

    def close(self) -> None:
        if self._fd is None:
            return
        try:
            for code in list(self._pressed_keys):
                self._emit(EV_KEY, code, 0)
            self._sync()
            if self._ioctl:
                self._ioctl(self._fd, UI_DEV_DESTROY, None)
        except Exception:
            pass
        os.close(self._fd)
        self._fd = None

    def _emit(self, ev_type: int, code: int, value: int) -> None:
        if self._fd is None:
            return
        ts = time.time()
        sec = int(ts)
        usec = int((ts - sec) * 1_000_000)
        event = struct.pack("llHHi", sec, usec, ev_type, code, value)
        try:
            os.write(self._fd, event)
        except OSError as exc:
            if exc.errno not in (errno.EAGAIN, errno.EWOULDBLOCK):
                raise

    def _sync(self) -> None:
        self._emit(EV_SYN, SYN_REPORT, 0)

    def _key_code(self, key: str) -> Optional[int]:
        if key in KEY_MAP:
            return KEY_MAP[key]
        if len(key) == 1:
            return ord(key.upper())
        return None

    def mousemove(self, x: int, y: int) -> None:
        x = max(0, min(self.width - 1, int(x)))
        y = max(0, min(self.height - 1, int(y)))
        if self._last_x is None or self._last_y is None:
            self._last_x, self._last_y = x, y
            return
        dx = x - self._last_x
        dy = y - self._last_y
        self._last_x, self._last_y = x, y
        if dx:
            self._emit(EV_REL, REL_X, dx)
        if dy:
            self._emit(EV_REL, REL_Y, dy)
        if dx or dy:
            self._sync()

    def mousedown(self, x: int, y: int, button: int) -> None:
        self.mousemove(x, y)
        btn = {1: BTN_LEFT, 2: BTN_MIDDLE, 3: BTN_RIGHT}.get(int(button), BTN_LEFT)
        self._emit(EV_KEY, btn, 1)
        self._sync()

    def mouseup(self, x: int, y: int, button: int) -> None:
        self.mousemove(x, y)
        btn = {1: BTN_LEFT, 2: BTN_MIDDLE, 3: BTN_RIGHT}.get(int(button), BTN_LEFT)
        self._emit(EV_KEY, btn, 0)
        self._sync()

    def click(self, x: int, y: int, button: int) -> None:
        self.mousedown(x, y, button)
        self.mouseup(x, y, button)

    def keydown(self, key: str) -> None:
        code = self._key_code(key)
        if code is None:
            return
        self._pressed_keys.add(code)
        self._emit(EV_KEY, code, 1)
        self._sync()

    def keyup(self, key: str) -> None:
        code = self._key_code(key)
        if code is None:
            return
        self._pressed_keys.discard(code)
        self._emit(EV_KEY, code, 0)
        self._sync()

    def wheel(self, delta_y: int) -> None:
        direction = -1 if int(delta_y) < 0 else 1
        self._emit(EV_REL, REL_WHEEL, direction)
        self._sync()
