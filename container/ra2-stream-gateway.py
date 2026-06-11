#!/usr/bin/env python3
"""Ultra-light browser gateway: HTTPS static app + WSS stream on one port."""

import asyncio
import json
import os
import shutil
import ssl
import subprocess
import sys
import time
from http import HTTPStatus
from pathlib import Path
from typing import Optional

from websockets.asyncio.server import serve

GATEWAY_PORT = int(os.environ.get("ULTRA_GATEWAY_PORT", "6080"))
TLS_CERT = os.environ.get("TLS_CERT", "/opt/ra2/tls/cert.pem")
TLS_KEY = os.environ.get("TLS_KEY", "/opt/ra2/tls/key.pem")
HELPER = os.environ.get("ULTRA_STREAM_HELPER", "/opt/ra2/stream-helper")
STREAM_CPUSET = os.environ.get("ULTRA_STREAM_CPUSET", "").strip()


def build_helper_command() -> list[str]:
    """Build the capture/encode helper command.

    When ULTRA_STREAM_CPUSET is set, pin the helper to dedicated CPUs so the
    GStreamer capture/convert/encode work never competes with a game core that
    is pinned to a single CPU. This complements (never replaces) the game-side
    affinity that is the core golden-master stability invariant.
    """
    if STREAM_CPUSET and shutil.which("taskset"):
        return ["taskset", "-c", STREAM_CPUSET, HELPER]
    return [HELPER]
WEB_ROOT = Path(os.environ.get("ULTRA_WEB_ROOT", "/opt/ra2/remote-ultra"))
PLAYER_ID = os.environ.get("PLAYER_ID", "1")
REQUESTED_LOG_ROOT = Path(os.environ.get("ULTRA_GAME_LOG_ROOT", "/home/commander/ra2-logs-root"))
FALLBACK_LOG_ROOT = Path(os.environ.get("WINEPREFIX", "/home/commander/.wine")) / "ra2-crash-logs"


def _path_is_mount(path: Path) -> bool:
    try:
        return any(line.split()[1] == str(path) for line in Path("/proc/mounts").read_text().splitlines())
    except Exception:
        return False


LOG_ROOT = REQUESTED_LOG_ROOT if _path_is_mount(REQUESTED_LOG_ROOT) else FALLBACK_LOG_ROOT
DIAGNOSTIC_DIR = Path(
    os.environ.get("ULTRA_GAME_DIAGNOSTIC_DIR", str(LOG_ROOT / f"player{PLAYER_ID}"))
)
INPUT_TRACE = Path(os.environ.get("ULTRA_INPUT_TRACE", str(DIAGNOSTIC_DIR / "input-events.log")))
GATEWAY_LOG = Path(os.environ.get("ULTRA_GATEWAY_LOG", str(DIAGNOSTIC_DIR / "gateway.log")))
DISPLAY = os.environ.get("DISPLAY", ":1")


def _display_dims() -> tuple[int, int]:
    """Game display size: ULTRA_VIDEO_WIDTH/HEIGHT override, else RESOLUTION."""
    res = os.environ.get("RESOLUTION", "1024x768").lower()
    try:
        res_w, res_h = (int(part) for part in res.split("x", 1))
    except ValueError:
        res_w, res_h = 1024, 768
    raw_w = os.environ.get("ULTRA_VIDEO_WIDTH", "").strip()
    raw_h = os.environ.get("ULTRA_VIDEO_HEIGHT", "").strip()
    try:
        width = int(raw_w) if raw_w else res_w
        height = int(raw_h) if raw_h else res_h
    except ValueError:
        width, height = res_w, res_h
    return max(1, width), max(1, height)


VIDEO_WIDTH, VIDEO_HEIGHT = _display_dims()

VIDEO_QUALITY_PRESETS = {
    "low": {"fps": 20},
    "balanced": {"fps": 24},
    "sharp": {"fps": 24},
}
ALLOWED_VIDEO_QUALITY = frozenset(VIDEO_QUALITY_PRESETS)
ALLOWED_VIDEO_BITRATES = frozenset({300000, 450000, 600000, 900000, 1200000, 1600000, 2000000})
# Encode resolutions the UI may request. "native" follows the game display
# (VIDEO_WIDTH x VIDEO_HEIGHT); fixed sizes downscale on the GPU before encode
# and input coordinates are mapped back onto the display.
ALLOWED_VIDEO_RESOLUTIONS = ("native", "960x720", "800x600", "640x480")
ALLOWED_VIDEO_CODECS = ("H264", "H265", "H265_10")
ALLOWED_AUDIO_QUALITY = frozenset({"44100", "48000"})
ALLOWED_AUDIO_BITRATES = frozenset({64000, 96000, 128000})
ALLOWED_INPUT_HZ = frozenset({60, 125, 200})
ALLOWED_AUDIO_ENCODERS = frozenset({"opus", "pcm"})
AVAILABLE_CACHE: dict = {}
FACTORY_CACHE: dict[str, bool] = {}
H265_QSV_FACTORIES = ("qsvh265enc", "msdkh265enc")
H265_VA_FACTORIES = ("vah265enc", "vaapih265enc")
H265_TEST_ENABLED = os.environ.get("ULTRA_H265_TEST_ENABLED", "0").lower() in {
    "1",
    "true",
    "yes",
}
ACTIVE_SESSION: Optional["StreamSession"] = None
ACTIVE_SESSION_LOCK = asyncio.Lock()

KEYSYM_MAP = {
    "ArrowUp": "Up",
    "ArrowDown": "Down",
    "ArrowLeft": "Left",
    "ArrowRight": "Right",
    "Backspace": "BackSpace",
    "Escape": "Escape",
    "Delete": "Delete",
    "Enter": "Return",
    " ": "space",
}

OPPOSITE_DIRECTION_KEYS = {
    "Up": "Down",
    "Down": "Up",
    "Left": "Right",
    "Right": "Left",
}


def _xdotool_key(key: object) -> str:
    return KEYSYM_MAP.get(str(key), str(key))


def _gst_factory_exists(name: str) -> bool:
    if name in FACTORY_CACHE:
        return FACTORY_CACHE[name]
    try:
        result = subprocess.run(
            ["gst-inspect-1.0", name],
            capture_output=True,
            timeout=5,
            check=False,
        )
        FACTORY_CACHE[name] = result.returncode == 0
        return FACTORY_CACHE[name]
    except Exception:
        FACTORY_CACHE[name] = False
        return False


def _factory_status(names: tuple[str, ...]) -> dict[str, str]:
    return {name: "present" if _gst_factory_exists(name) else "missing" for name in names}


P010_SUPPORT_CACHE: dict[str, bool] = {}


def _vah265enc_supports_p010() -> bool:
    """True when vah265enc advertises P010_10LE sink caps (HEVC Main10 encode)."""
    if "vah265enc" in P010_SUPPORT_CACHE:
        return P010_SUPPORT_CACHE["vah265enc"]
    supported = False
    try:
        result = subprocess.run(
            ["gst-inspect-1.0", "vah265enc"],
            capture_output=True,
            timeout=5,
            check=False,
        )
        supported = result.returncode == 0 and b"P010_10LE" in result.stdout
    except Exception:
        supported = False
    P010_SUPPORT_CACHE["vah265enc"] = supported
    return supported


def _stream_size(resolution: str) -> tuple[int, int]:
    if resolution == "native":
        return VIDEO_WIDTH, VIDEO_HEIGHT
    width, _, height = resolution.partition("x")
    return int(width), int(height)


def _h265_unavailable_reason() -> str:
    qsv = _factory_status(H265_QSV_FACTORIES)
    va = _factory_status(H265_VA_FACTORIES)
    present_qsv = [name for name, status in qsv.items() if status == "present"]
    present_va = [name for name, status in va.items() if status == "present"]
    if not present_qsv and not present_va:
        return (
            "H265 disabled; no QSV/VA HEVC encoder factory found "
            f"(qsv={qsv}, va={va}); see video-diagnostics.log"
        )
    if not H265_TEST_ENABLED:
        return (
            "H265 test mode is disabled; set ULTRA_H265_TEST_ENABLED=1 to use the available "
            f"HEVC encoders (qsv={qsv}, va={va}); see video-diagnostics.log"
        )
    if not present_qsv:
        return (
            "H265 enabled for testing with VA HEVC; QSV HEVC is missing "
            f"(qsv={qsv}, va={va}); see video-diagnostics.log"
        )
    return (
        "H265 enabled for testing with QSV/VA HEVC "
        f"(qsv={present_qsv}, va={present_va}); see video-diagnostics.log"
    )


def _video_codec_available(codec: str) -> bool:
    codec = codec.upper()
    if codec in {"H264", "AVC"}:
        return (
            _gst_factory_exists("vah264enc")
            or _gst_factory_exists("vaapih264enc")
            or _gst_factory_exists("x264enc")
        )
    if codec in {"H265", "HEVC"}:
        if not H265_TEST_ENABLED:
            return False
        return any(_gst_factory_exists(factory) for factory in (*H265_QSV_FACTORIES, *H265_VA_FACTORIES))
    if codec in {"H265_10", "HEVC10"}:
        if not H265_TEST_ENABLED:
            return False
        return _gst_factory_exists("vah265enc") and _vah265enc_supports_p010()
    return False


def _h265_10_unavailable_reason() -> str:
    if not _gst_factory_exists("vah265enc"):
        return "H265 10-bit requires the vah265enc encoder, which is missing; see video-diagnostics.log"
    if not _vah265enc_supports_p010():
        return "vah265enc does not accept P010_10LE (no HEVC Main10 encode) on this GPU/driver; see video-diagnostics.log"
    if not H265_TEST_ENABLED:
        return "H265 is disabled; set ULTRA_H265_TEST_ENABLED=1 to enable HEVC encodes"
    return "available"


def _audio_encoder_available(encoder: str) -> bool:
    encoder = encoder.lower()
    if encoder == "pcm":
        return True
    if encoder == "opus":
        return _gst_factory_exists("opusenc")
    return False


def default_settings() -> dict:
    quality = "balanced"
    preset = VIDEO_QUALITY_PRESETS[quality]
    return {
        "videoQuality": quality,
        "videoCodec": os.environ.get("ULTRA_VIDEO_CODEC", "H264").upper(),
        "videoResolution": "native",
        "audioEncoder": os.environ.get("ULTRA_AUDIO_CODEC", "opus").lower(),
        "audioQuality": str(int(os.environ.get("ULTRA_AUDIO_RATE", "44100"))),
        "audioBitrate": int(os.environ.get("ULTRA_AUDIO_BITRATE", "64000")),
        "audioTransportRate": int(os.environ.get("ULTRA_AUDIO_TRANSPORT_RATE", "48000")),
        "inputMoveHz": int(os.environ.get("ULTRA_INPUT_MOVE_HZ", "125")),
        "videoBitrate": int(os.environ.get("ULTRA_VIDEO_BITRATE", "900000")),
        "videoFps": int(os.environ.get("ULTRA_VIDEO_FPS", str(preset["fps"]))),
    }


def get_available_options() -> dict:
    if AVAILABLE_CACHE:
        return AVAILABLE_CACHE

    video_codecs = []
    unavailable_video = {}
    for codec in ALLOWED_VIDEO_CODECS:
        if _video_codec_available(codec):
            video_codecs.append(codec)
        elif codec == "H265":
            unavailable_video[codec] = _h265_unavailable_reason()
        elif codec == "H265_10":
            unavailable_video[codec] = _h265_10_unavailable_reason()
        else:
            unavailable_video[codec] = "hardware encoder not found on server"

    audio_encoders = []
    unavailable_audio = {}
    for encoder in ("opus", "pcm"):
        if _audio_encoder_available(encoder):
            audio_encoders.append(encoder)
        else:
            unavailable_audio[encoder] = "encoder not found on server"

    available = {
        "videoQuality": sorted(ALLOWED_VIDEO_QUALITY),
        "videoBitrate": sorted(ALLOWED_VIDEO_BITRATES),
        "videoCodec": video_codecs,
        "videoResolution": list(ALLOWED_VIDEO_RESOLUTIONS),
        "audioEncoder": audio_encoders,
        "audioQuality": sorted(ALLOWED_AUDIO_QUALITY),
        "audioBitrate": sorted(ALLOWED_AUDIO_BITRATES),
        "inputMoveHz": sorted(ALLOWED_INPUT_HZ),
        "unavailable": {
            "audioEncoder": unavailable_audio,
            "videoCodec": unavailable_video,
        },
    }
    AVAILABLE_CACHE.update(available)
    return available


def validate_settings(requested: Optional[dict]) -> dict:
    defaults = default_settings()
    requested = requested or {}
    active = dict(defaults)
    fallbacks: list[dict] = []

    quality = str(requested.get("videoQuality", defaults["videoQuality"])).lower()
    if quality not in ALLOWED_VIDEO_QUALITY:
        fallbacks.append(
            {
                "field": "videoQuality",
                "requested": quality,
                "active": defaults["videoQuality"],
                "reason": "unsupported preset",
            }
        )
        quality = defaults["videoQuality"]
    active["videoQuality"] = quality
    preset = VIDEO_QUALITY_PRESETS[quality]
    active["videoFps"] = preset["fps"]

    try:
        video_bitrate = int(requested.get("videoBitrate", defaults["videoBitrate"]))
    except (TypeError, ValueError):
        video_bitrate = defaults["videoBitrate"]
    if video_bitrate not in ALLOWED_VIDEO_BITRATES:
        fallbacks.append(
            {
                "field": "videoBitrate",
                "requested": video_bitrate,
                "active": defaults["videoBitrate"],
                "reason": "unsupported video bitrate",
            }
        )
        video_bitrate = defaults["videoBitrate"]
    active["videoBitrate"] = video_bitrate

    codec = str(requested.get("videoCodec", defaults["videoCodec"])).upper()
    if codec not in {"H264", "H265", "HEVC", "AVC", "H265_10", "HEVC10"}:
        fallbacks.append(
            {
                "field": "videoCodec",
                "requested": codec,
                "active": defaults["videoCodec"],
                "reason": "unsupported codec",
            }
        )
        codec = defaults["videoCodec"]
    if codec in {"HEVC"}:
        codec = "H265"
    if codec in {"AVC"}:
        codec = "H264"
    if codec in {"HEVC10"}:
        codec = "H265_10"
    if codec == "H265_10" and not _video_codec_available("H265_10"):
        fallback_codec = "H265" if _video_codec_available("H265") else "H264"
        fallbacks.append(
            {
                "field": "videoCodec",
                "requested": "H265_10",
                "active": fallback_codec,
                "reason": _h265_10_unavailable_reason(),
            }
        )
        codec = fallback_codec
    if codec == "H265" and not _video_codec_available("H265"):
        fallbacks.append(
            {
                "field": "videoCodec",
                "requested": "H265",
                "active": "H264",
                "reason": _h265_unavailable_reason(),
            }
        )
        codec = "H264"
    if not _video_codec_available(codec):
        fallbacks.append(
            {
                "field": "videoCodec",
                "requested": codec,
                "active": "H264" if _video_codec_available("H264") else defaults["videoCodec"],
                "reason": "encoder unavailable on server",
            }
        )
        codec = "H264" if _video_codec_available("H264") else defaults["videoCodec"]
    active["videoCodec"] = codec

    resolution = str(requested.get("videoResolution", defaults["videoResolution"])).lower()
    if resolution not in ALLOWED_VIDEO_RESOLUTIONS:
        fallbacks.append(
            {
                "field": "videoResolution",
                "requested": resolution,
                "active": defaults["videoResolution"],
                "reason": "unsupported stream resolution",
            }
        )
        resolution = defaults["videoResolution"]
    active["videoResolution"] = resolution

    audio_encoder = str(requested.get("audioEncoder", defaults["audioEncoder"])).lower()
    if audio_encoder not in ALLOWED_AUDIO_ENCODERS:
        fallbacks.append(
            {
                "field": "audioEncoder",
                "requested": audio_encoder,
                "active": defaults["audioEncoder"],
                "reason": "unsupported audio encoder",
            }
        )
        audio_encoder = defaults["audioEncoder"]
    if not _audio_encoder_available(audio_encoder):
        fallbacks.append(
            {
                "field": "audioEncoder",
                "requested": audio_encoder,
                "active": "pcm",
                "reason": "encoder unavailable on server",
            }
        )
        audio_encoder = "pcm"
    active["audioEncoder"] = audio_encoder
    active["audioTransportRate"] = 48000 if audio_encoder == "opus" else int(active["audioQuality"])

    audio_quality = str(requested.get("audioQuality", defaults["audioQuality"]))
    if audio_quality not in ALLOWED_AUDIO_QUALITY:
        fallbacks.append(
            {
                "field": "audioQuality",
                "requested": audio_quality,
                "active": defaults["audioQuality"],
                "reason": "unsupported sample rate",
            }
        )
        audio_quality = defaults["audioQuality"]
    active["audioQuality"] = audio_quality

    try:
        audio_bitrate = int(requested.get("audioBitrate", defaults["audioBitrate"]))
    except (TypeError, ValueError):
        audio_bitrate = defaults["audioBitrate"]
    if audio_bitrate not in ALLOWED_AUDIO_BITRATES:
        fallbacks.append(
            {
                "field": "audioBitrate",
                "requested": audio_bitrate,
                "active": defaults["audioBitrate"],
                "reason": "unsupported Opus bitrate",
            }
        )
        audio_bitrate = defaults["audioBitrate"]
    active["audioBitrate"] = audio_bitrate

    try:
        move_hz = int(requested.get("inputMoveHz", defaults["inputMoveHz"]))
    except (TypeError, ValueError):
        move_hz = defaults["inputMoveHz"]
    if move_hz not in ALLOWED_INPUT_HZ:
        fallbacks.append(
            {
                "field": "inputMoveHz",
                "requested": move_hz,
                "active": defaults["inputMoveHz"],
                "reason": "unsupported polling rate",
            }
        )
        move_hz = defaults["inputMoveHz"]
    active["inputMoveHz"] = move_hz

    return {
        "requested": {
            "videoQuality": requested.get("videoQuality", defaults["videoQuality"]),
            "videoCodec": requested.get("videoCodec", defaults["videoCodec"]),
            "videoResolution": requested.get("videoResolution", defaults["videoResolution"]),
            "videoBitrate": requested.get("videoBitrate", defaults["videoBitrate"]),
            "audioEncoder": requested.get("audioEncoder", defaults["audioEncoder"]),
            "audioQuality": requested.get("audioQuality", defaults["audioQuality"]),
            "audioBitrate": requested.get("audioBitrate", defaults["audioBitrate"]),
            "inputMoveHz": requested.get("inputMoveHz", defaults["inputMoveHz"]),
        },
        "active": active,
        "fallbacks": fallbacks,
    }


def build_helper_env(active: dict) -> dict:
    codec = active["videoCodec"]
    # H265_10 is a UI-level codec choice; the helper sees H265 plus a bit depth.
    helper_codec = "H265" if codec == "H265_10" else codec
    bit_depth = "10" if codec == "H265_10" else "8"
    stream_width, stream_height = _stream_size(active.get("videoResolution", "native"))
    return {
        "ULTRA_VIDEO_CODEC": helper_codec,
        "ULTRA_VIDEO_BIT_DEPTH": bit_depth,
        "ULTRA_VIDEO_BITRATE": str(active["videoBitrate"]),
        "ULTRA_VIDEO_FPS": str(active["videoFps"]),
        "ULTRA_VIDEO_WIDTH": str(stream_width),
        "ULTRA_VIDEO_HEIGHT": str(stream_height),
        "ULTRA_AUDIO_CODEC": active["audioEncoder"],
        "ULTRA_AUDIO_BITRATE": str(active["audioBitrate"]),
        "ULTRA_AUDIO_RATE": active["audioQuality"],
        "ULTRA_AUDIO_TRANSPORT_RATE": str(active["audioTransportRate"]),
    }


def _clamp_int(value: object, minimum: int, maximum: int) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        parsed = minimum
    return max(minimum, min(maximum, parsed))


def _ssl_context() -> Optional[ssl.SSLContext]:
    if os.environ.get("ULTRA_GATEWAY_TLS", "0") != "1":
        return None
    if not (Path(TLS_CERT).is_file() and Path(TLS_KEY).is_file()):
        return None
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(TLS_CERT, TLS_KEY)
    return ctx


def _mime(path: Path) -> str:
    if path.suffix == ".js":
        return "text/javascript; charset=utf-8"
    if path.suffix == ".css":
        return "text/css; charset=utf-8"
    return "text/html; charset=utf-8"


def _static_body(path: str) -> Optional[tuple[str, bytes]]:
    rel = path.lstrip("/") or "index.html"
    if rel == "stream":
        return None
    target = WEB_ROOT / rel
    if not target.is_file():
        if rel != "index.html":
            return None
        target = WEB_ROOT / "index.html"
        if not target.is_file():
            return None
    return _mime(target), target.read_bytes()


class InputDispatcher:
    def __init__(self, move_hz: int = 125) -> None:
        self.move_hz = max(30, min(250, int(move_hz)))
        self.last_move_at = 0.0
        self.last_focus_at = 0.0
        self.last_trace_move_at = 0.0
        self.last_wheel_at = 0.0
        self.active_keys: set[str] = set()
        self.stream_width = VIDEO_WIDTH
        self.stream_height = VIDEO_HEIGHT

    def set_move_hz(self, move_hz: int) -> None:
        self.move_hz = max(30, min(250, int(move_hz)))

    def set_stream_size(self, width: int, height: int) -> None:
        self.stream_width = max(1, int(width))
        self.stream_height = max(1, int(height))

    def _map_xy(self, event: dict) -> tuple[int, int]:
        """Map stream-space pointer coords onto game display pixels.

        The encoded stream may be downscaled (videoResolution), but xdotool
        operates on the Xvfb display, so scale up before clamping.
        """
        x = _clamp_int(event.get("x", 0), 0, self.stream_width - 1)
        y = _clamp_int(event.get("y", 0), 0, self.stream_height - 1)
        if self.stream_width != VIDEO_WIDTH:
            x = x * VIDEO_WIDTH // self.stream_width
        if self.stream_height != VIDEO_HEIGHT:
            y = y * VIDEO_HEIGHT // self.stream_height
        return min(x, VIDEO_WIDTH - 1), min(y, VIDEO_HEIGHT - 1)

    def _xdotool(self, args: list[str]) -> None:
        env = {**os.environ, "DISPLAY": DISPLAY}
        try:
            subprocess.run(
                ["xdotool", *args],
                env=env,
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=2,
            )
        except Exception as exc:
            print(f"[ultra-gateway] xdotool failed: {exc}", flush=True)

    def _focus_game_window(self) -> None:
        now = time.monotonic()
        if now - self.last_focus_at < 1.0:
            return
        self.last_focus_at = now
        env = {**os.environ, "DISPLAY": DISPLAY}
        try:
            subprocess.run(
                ["xdotool", "search", "--name", "Yuri's Revenge", "windowactivate", "%@"],
                env=env,
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=2,
            )
        except Exception as exc:
            print(f"[ultra-gateway] window focus failed: {exc}", flush=True)

    def _trace_event(self, event: dict, note: str = "") -> None:
        kind = str(event.get("type", "unknown"))
        now = time.monotonic()
        if kind == "mousemove":
            if now - self.last_trace_move_at < 1.0:
                return
            self.last_trace_move_at = now
        fields = [f"ts={time.time():.3f}", f"type={kind}"]
        for key in ("key", "button", "x", "y", "deltaY"):
            if key in event:
                fields.append(f"{key}={event[key]}")
        if note:
            fields.append(f"note={note}")
        if self.active_keys:
            fields.append(f"active_keys={','.join(sorted(self.active_keys))}")
        try:
            INPUT_TRACE.parent.mkdir(parents=True, exist_ok=True)
            with INPUT_TRACE.open("a", encoding="utf-8") as trace:
                trace.write(" ".join(fields) + "\n")
            if INPUT_TRACE.stat().st_size > 65536:
                lines = INPUT_TRACE.read_text(encoding="utf-8", errors="replace").splitlines()[-300:]
                INPUT_TRACE.write_text("\n".join(lines) + "\n", encoding="utf-8")
        except Exception as exc:
            print(f"[ultra-gateway] input trace failed: {exc}", flush=True)

    def handle(self, event: dict) -> None:
        kind = event.get("type")
        if kind == "mousemove":
            now = time.monotonic()
            if now - self.last_move_at < 1.0 / self.move_hz:
                return
            self.last_move_at = now
            self._trace_event(event)
            x, y = self._map_xy(event)
            self._xdotool(["mousemove", str(x), str(y)])
            return
        if kind == "mousedown":
            self._focus_game_window()
            self._trace_event(event)
            x, y = self._map_xy(event)
            button = _clamp_int(event.get("button", 1), 1, 9)
            self._xdotool(["mousemove", str(x), str(y)])
            self._xdotool(["mousedown", str(button)])
            return
        if kind == "mouseup":
            self._focus_game_window()
            self._trace_event(event)
            button = _clamp_int(event.get("button", 1), 1, 9)
            x, y = self._map_xy(event)
            self._xdotool(["mousemove", str(x), str(y)])
            self._xdotool(["mouseup", str(button)])
            return
        if kind == "click":
            self._trace_event(event)
            x, y = self._map_xy(event)
            button = _clamp_int(event.get("button", 1), 1, 9)
            self._xdotool(["mousemove", str(x), str(y)])
            self._xdotool(["click", str(button)])
            return
        if kind == "keydown":
            self._focus_game_window()
            key = event.get("key")
            if key:
                xkey = _xdotool_key(key)
                if xkey in self.active_keys:
                    self._trace_event(event, f"ignored-duplicate={xkey}")
                    return
                opposite = OPPOSITE_DIRECTION_KEYS.get(xkey)
                if opposite in self.active_keys:
                    self._trace_event(event, f"release_opposite={opposite}")
                    self._xdotool(["keyup", opposite])
                    self.active_keys.discard(opposite)
                self.active_keys.add(xkey)
                self._trace_event(event, f"mapped={xkey}")
                self._xdotool(["keydown", xkey])
            return
        if kind == "keyup":
            self._focus_game_window()
            key = event.get("key")
            if key:
                xkey = _xdotool_key(key)
                self.active_keys.discard(xkey)
                self._trace_event(event, f"mapped={xkey}")
                self._xdotool(["keyup", xkey])
            return
        if kind == "keyup_all":
            self._trace_event(event, "release_all")
            self.release_all_keys()
            return
        if kind == "wheel":
            now = time.monotonic()
            if now - self.last_wheel_at < 0.25:
                return
            self.last_wheel_at = now
            direction = "4" if event.get("deltaY", 0) < 0 else "5"
            self._trace_event(event, f"mapped={direction}")
            self._focus_game_window()
            self._xdotool(["click", direction])
            return

    def release_all_keys(self) -> None:
        if not self.active_keys:
            return
        for key in sorted(self.active_keys):
            self._xdotool(["keyup", key])
        self.active_keys.clear()


class StreamSession:
    def __init__(self, websocket) -> None:
        self.websocket = websocket
        self.helper: Optional[subprocess.Popen[str]] = None
        self.reader_task: Optional[asyncio.Task] = None
        defaults = default_settings()
        self.input = InputDispatcher(move_hz=defaults["inputMoveHz"])
        self.connected_at = time.monotonic()
        self.frames_sent = 0
        self.active_settings = defaults
        self.requested_settings: dict = {}
        self.fallbacks: list[dict] = []
        self.helper_env: dict = build_helper_env(defaults)
        self.stream_width = int(self.helper_env["ULTRA_VIDEO_WIDTH"])
        self.stream_height = int(self.helper_env["ULTRA_VIDEO_HEIGHT"])
        self.replaced = False

    async def become_active(self) -> None:
        global ACTIVE_SESSION
        async with ACTIVE_SESSION_LOCK:
            previous = ACTIVE_SESSION
            if previous and previous is not self:
                previous.replaced = True
                print(
                    f"[ultra-gateway] replacing previous stream session (player {PLAYER_ID})",
                    flush=True,
                )
                await previous.stop_helper("replaced_by_new_session")
                await previous.websocket.close(1012, "replaced by a newer stream session")
            ACTIVE_SESSION = self

    async def clear_active(self) -> None:
        global ACTIVE_SESSION
        async with ACTIVE_SESSION_LOCK:
            if ACTIVE_SESSION is self:
                ACTIVE_SESSION = None

    async def start_helper(self) -> None:
        if self.helper and self.helper.poll() is None:
            return
        await self.stop_helper("restart")
        print(
            f"[ultra-gateway] starting stream helper codec={self.active_settings['videoCodec']} "
            f"size={self.stream_width}x{self.stream_height} "
            f"bitrate={self.active_settings['videoBitrate']} "
            f"fps={self.active_settings['videoFps']} "
            f"audio={self.active_settings['audioEncoder']}@{self.active_settings['audioBitrate']}bps/"
            f"{self.active_settings['audioQuality']}Hz "
            f"cpuset={STREAM_CPUSET or 'unpinned'} "
            f"(player {PLAYER_ID})",
            flush=True,
        )
        env = {**os.environ, **self.helper_env}
        self.helper = subprocess.Popen(
            build_helper_command(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=env,
        )
        self.reader_task = asyncio.create_task(self._read_helper_stdout())
        asyncio.create_task(self._read_helper_stderr())

    async def stop_helper(self, reason: str = "stop") -> None:
        if self.reader_task:
            self.reader_task.cancel()
            try:
                await self.reader_task
            except asyncio.CancelledError:
                pass
            self.reader_task = None
        if self.helper and self.helper.poll() is None:
            print(f"[ultra-gateway] stopping helper reason={reason}", flush=True)
            self.helper.terminate()
            try:
                await asyncio.to_thread(self.helper.wait, 3)
            except Exception:
                self.helper.kill()
        self.helper = None

    async def _read_helper_stderr(self) -> None:
        if not self.helper or not self.helper.stderr:
            return
        while True:
            line = await asyncio.to_thread(self.helper.stderr.readline)
            if not line:
                break
            print(f"[stream-helper] {line.rstrip()}", flush=True)

    async def _read_helper_stdout(self) -> None:
        if not self.helper or not self.helper.stdout:
            return
        while True:
            line = await asyncio.to_thread(self.helper.stdout.readline)
            if not line:
                break
            line = line.strip()
            if not line:
                continue
            # Hot path: the helper emits fixed printf JSON, so a prefix check
            # replaces a full json.loads per frame/packet on the J4125.
            if not line.startswith("{"):
                print(f"[ultra-gateway] bad helper line: {line[:120]}", flush=True)
                continue
            if line.startswith('{"type":"video"'):
                self.frames_sent += 1
            await self.websocket.send(line)
        await self.stop_helper("helper_eof")

    async def handle_client_message(self, raw: str) -> None:
        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            return
        if msg.get("type") == "ping":
            await self.websocket.send(
                json.dumps(
                    {
                        "type": "pong",
                        "ts": int(time.time() * 1000),
                        "clientT": msg.get("t"),
                    }
                )
            )
            return
        if msg.get("type") == "start":
            validated = validate_settings(msg.get("settings"))
            self.requested_settings = validated["requested"]
            self.active_settings = validated["active"]
            self.fallbacks = validated["fallbacks"]
            self.helper_env = build_helper_env(self.active_settings)
            self.stream_width = int(self.helper_env["ULTRA_VIDEO_WIDTH"])
            self.stream_height = int(self.helper_env["ULTRA_VIDEO_HEIGHT"])
            self.input.set_stream_size(self.stream_width, self.stream_height)
            self.input.set_move_hz(self.active_settings["inputMoveHz"])
            await self.become_active()
            await self.start_helper()
            await self.websocket.send(
                json.dumps(
                    {
                        "type": "ready",
                        "width": self.stream_width,
                        "height": self.stream_height,
                        "player": PLAYER_ID,
                        "requested": self.requested_settings,
                        "active": self.active_settings,
                        "available": get_available_options(),
                        "fallbacks": self.fallbacks,
                        "transport": {
                            "video": (
                                f"{self.active_settings['videoCodec']} "
                                f"{self.stream_width}x{self.stream_height}@"
                                f"{self.active_settings['videoBitrate']}bps/"
                                f"{self.active_settings['videoFps']}fps"
                            ),
                            "audio": (
                                f"{self.active_settings['audioEncoder']}@"
                                f"{self.active_settings['audioBitrate']}bps/"
                                f"source{self.active_settings['audioQuality']}Hz"
                                f"->transport{self.active_settings['audioTransportRate']}Hz"
                            ),
                            "input": f"{self.active_settings['inputMoveHz']}Hz",
                        },
                    }
                )
            )
            return
        if msg.get("type") == "stop":
            self.input.release_all_keys()
            await self.stop_helper("client_stop")
            return
        if msg.get("type") in {
            "mousemove",
            "mousedown",
            "mouseup",
            "click",
            "keydown",
            "keyup",
            "keyup_all",
            "wheel",
        }:
            self.input.handle(msg)


def process_request(connection, request):
    served = _static_body(request.path)
    if served is None:
        return None
    content_type, body = served
    response = connection.respond(HTTPStatus.OK, body.decode("utf-8"))
    response.headers["Content-Type"] = content_type
    response.headers["Cache-Control"] = "no-store"
    return response


async def stream_handler(websocket) -> None:
    if websocket.request.path not in {"/stream", "/stream/"}:
        await websocket.close(1008, "connect to /stream")
        return

    session = StreamSession(websocket)
    print(f"[ultra-gateway] client connected (player {PLAYER_ID})", flush=True)
    try:
        await websocket.send(
            json.dumps(
                {
                    "type": "hello",
                    "player": PLAYER_ID,
                    "codec": os.environ.get("ULTRA_VIDEO_CODEC", "H264"),
                    "fps": int(os.environ.get("ULTRA_VIDEO_FPS", "24")),
                    "defaults": default_settings(),
                    "available": get_available_options(),
                }
            )
        )
        async for raw in websocket:
            await session.handle_client_message(raw)
    finally:
        session.input.release_all_keys()
        await session.stop_helper("disconnect")
        await session.clear_active()
        elapsed = time.monotonic() - session.connected_at
        print(
            f"[ultra-gateway] client disconnected frames={session.frames_sent} "
            f"elapsed={elapsed:.1f}s (player {PLAYER_ID})",
            flush=True,
        )


async def main() -> None:
    if not Path(HELPER).is_file():
        print(f"[ultra-gateway] helper missing: {HELPER}", file=sys.stderr)
        sys.exit(1)

    ssl_ctx = _ssl_context()
    scheme = "wss" if ssl_ctx else "ws"
    print(
        f"[ultra-gateway] listening on {scheme}://0.0.0.0:{GATEWAY_PORT} "
        f"(player {PLAYER_ID}, web={WEB_ROOT})",
        flush=True,
    )

    async with serve(
        stream_handler,
        "0.0.0.0",
        GATEWAY_PORT,
        ssl=ssl_ctx,
        process_request=process_request,
        max_size=16 * 1024 * 1024,
        ping_interval=20,
        ping_timeout=60,
    ):
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
