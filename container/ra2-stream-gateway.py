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
DISPLAY_ENV = Path(os.environ.get("ULTRA_DISPLAY_ENV", "/home/commander/.ra2/display.env"))
ENSURE_INI_LINKS = Path(os.environ.get("ULTRA_ENSURE_INI_LINKS", "/opt/ra2/ensure-game-ini-links.sh"))
# Resolution is fixed at container boot (RESOLUTION / display.env) and game launch
# (sync-game-transport.sh). The gateway never changes native or stream dimensions.


def _read_display_env() -> dict[str, str]:
    values: dict[str, str] = {}
    if not DISPLAY_ENV.is_file():
        return values
    try:
        for line in DISPLAY_ENV.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    except Exception:
        return values
    return values


def _default_resolution() -> str:
    saved = _read_display_env().get("RESOLUTION", "").lower()
    if saved and "x" in saved:
        return saved
    return os.environ.get("RESOLUTION", "960x720").lower()


def _display_dims() -> tuple[int, int]:
    """Native game display size from display.env, then container env."""
    saved = _read_display_env()
    res = saved.get("RESOLUTION") or os.environ.get("RESOLUTION", "960x720")
    res = str(res).lower()
    try:
        width, height = (int(part) for part in res.split("x", 1))
    except ValueError:
        width, height = 1024, 768
    raw_w = os.environ.get("ULTRA_VIDEO_WIDTH", "").strip()
    raw_h = os.environ.get("ULTRA_VIDEO_HEIGHT", "").strip()
    if not raw_w and not raw_h:
        return max(1, width), max(1, height)
    try:
        width = int(raw_w) if raw_w else width
        height = int(raw_h) if raw_h else height
    except ValueError:
        pass
    return max(1, width), max(1, height)


def refresh_display_dims() -> tuple[int, int]:
    global VIDEO_WIDTH, VIDEO_HEIGHT
    VIDEO_WIDTH, VIDEO_HEIGHT = _display_dims()
    return VIDEO_WIDTH, VIDEO_HEIGHT


def _game_process_running() -> bool:
    game_process = os.environ.get("ULTRA_GAME_PROCESS", "gamemd.exe")
    try:
        result = subprocess.run(
            ["pgrep", "-f", game_process],
            capture_output=True,
            timeout=2,
            check=False,
        )
        return result.returncode == 0
    except Exception:
        return False


def _ensure_game_ini_links() -> None:
    if not ENSURE_INI_LINKS.is_file():
        return
    try:
        subprocess.run(
            ["/bin/sh", str(ENSURE_INI_LINKS)],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except Exception as exc:
        print(f"[ultra-gateway] ini link ensure failed: {exc}", flush=True)


VIDEO_WIDTH, VIDEO_HEIGHT = _display_dims()

# 480p / 720p / 1080p tiers (4:3). Exposed to Wine via configure-display-modes.sh.
RESOLUTION_TIERS: dict[str, tuple[int, int]] = {
    "480p": (640, 480),
    "720p": (960, 720),
    "1080p": (1440, 1080),
}
GAME_DISPLAY_MODES: tuple[tuple[int, int], ...] = tuple(RESOLUTION_TIERS.values())
SYNC_AUDIO_TRANSPORT = Path(
    os.environ.get("ULTRA_SYNC_AUDIO_TRANSPORT", "/opt/ra2/sync-audio-transport.sh")
)
MAX_DISPLAY_WIDTH = max(width for width, _ in GAME_DISPLAY_MODES)
MAX_DISPLAY_HEIGHT = max(height for _, height in GAME_DISPLAY_MODES)
MIN_DISPLAY_WIDTH = min(width for width, _ in GAME_DISPLAY_MODES)
MIN_DISPLAY_HEIGHT = min(height for _, height in GAME_DISPLAY_MODES)
MAX_VIDEO_FPS = 30
VIDEO_QUALITY_PRESETS = {
    "low": {"fps": 20},
    "balanced": {"fps": 24},
    "sharp": {"fps": MAX_VIDEO_FPS},
}
ALLOWED_VIDEO_QUALITY = frozenset(VIDEO_QUALITY_PRESETS)
ALLOWED_VIDEO_BITRATES = frozenset({300000, 450000, 600000, 900000, 1200000, 1600000, 2000000})
ALLOWED_VIDEO_RESOLUTIONS = tuple(
    f"{width}x{height}" for width, height in GAME_DISPLAY_MODES
)
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


def _tier_for_dims(width: int, height: int) -> str:
    if (width, height) in GAME_DISPLAY_MODES:
        for tier, dims in RESOLUTION_TIERS.items():
            if dims == (width, height):
                return tier
    best_tier = "720p"
    best_dist = 10**9
    for tier, (_, tier_height) in RESOLUTION_TIERS.items():
        dist = abs(height - tier_height)
        if dist < best_dist:
            best_dist = dist
            best_tier = tier
    return best_tier


def _snap_to_tier_dims(width: int, height: int) -> tuple[int, int]:
    return RESOLUTION_TIERS[_tier_for_dims(width, height)]


def _is_allowed_game_resolution(width: int, height: int) -> bool:
    # Only exact 480p/720p/1080p tiers. RA2 briefly reports values like
    # 1024x768 during map load; treating those as real changes restarts Xvfb
    # and freezes the game.
    return (width, height) in GAME_DISPLAY_MODES


def _sync_audio_transport(active: dict) -> None:
    if not SYNC_AUDIO_TRANSPORT.is_file():
        return
    try:
        subprocess.run(
            [
                "/bin/sh",
                str(SYNC_AUDIO_TRANSPORT),
                str(active["audioQuality"]),
                str(active["audioTransportRate"]),
                str(active["audioEncoder"]),
            ],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except Exception as exc:
        print(f"[ultra-gateway] audio transport sync failed: {exc}", flush=True)


def _configured_display_dims() -> tuple[int, int]:
    """Boot-time display size from display.env / RESOLUTION only (never live X11 or INI)."""
    width, height = refresh_display_dims()
    if _is_allowed_game_resolution(width, height):
        return width, height
    return _snap_to_tier_dims(width, height)


def _format_display_resolution(width: int, height: int) -> str:
    return f"{width}x{height}"


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
    display_w, display_h = _configured_display_dims()
    return {
        "videoQuality": quality,
        "videoCodec": os.environ.get("ULTRA_VIDEO_CODEC", "H265_10").upper(),
        "displayResolution": _format_display_resolution(display_w, display_h),
        "audioEncoder": os.environ.get("ULTRA_AUDIO_CODEC", "opus").lower(),
        "audioQuality": (
            "48000"
            if os.environ.get("ULTRA_AUDIO_CODEC", "opus").lower() == "opus"
            else str(int(os.environ.get("ULTRA_AUDIO_RATE", "44100")))
        ),
        "audioBitrate": int(os.environ.get("ULTRA_AUDIO_BITRATE", "64000")),
        # Native Pulse capture and stream encode always share one rate.
        "audioTransportRate": (
            48000
            if os.environ.get("ULTRA_AUDIO_CODEC", "opus").lower() == "opus"
            else int(os.environ.get("ULTRA_AUDIO_RATE", "44100"))
        ),
        "inputMoveHz": int(os.environ.get("ULTRA_INPUT_MOVE_HZ", "60")),
        "videoBitrate": int(os.environ.get("ULTRA_VIDEO_BITRATE", "2000000")),
        "videoFps": min(
            int(os.environ.get("ULTRA_VIDEO_FPS", str(preset["fps"]))),
            MAX_VIDEO_FPS,
        ),
    }


def get_available_options() -> dict:
    if not AVAILABLE_CACHE:
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

        stream_codec_lock = os.environ.get("ULTRA_STREAM_CODEC_LOCK", "").strip().upper()
        if stream_codec_lock == "H264":
            for codec in list(video_codecs):
                if codec != "H264":
                    unavailable_video[codec] = "server locked to H264 for stable mission play"
            video_codecs = [codec for codec in video_codecs if codec == "H264"]

        AVAILABLE_CACHE.update(
            {
                "videoQuality": sorted(ALLOWED_VIDEO_QUALITY),
                "videoBitrate": sorted(ALLOWED_VIDEO_BITRATES),
                "videoCodec": video_codecs,
                "audioEncoder": audio_encoders,
                "audioQuality": sorted(ALLOWED_AUDIO_QUALITY),
                "audioBitrate": sorted(ALLOWED_AUDIO_BITRATES),
                "inputMoveHz": sorted(ALLOWED_INPUT_HZ),
                "streamCodecLock": stream_codec_lock if stream_codec_lock else None,
                "unavailable": {
                    "audioEncoder": unavailable_audio,
                    "videoCodec": unavailable_video,
                },
            }
        )

    available = dict(AVAILABLE_CACHE)
    display_w, display_h = _configured_display_dims()
    available["displayResolution"] = _format_display_resolution(display_w, display_h)
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
    active["videoFps"] = min(preset["fps"], MAX_VIDEO_FPS)

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
    stream_codec_lock = os.environ.get("ULTRA_STREAM_CODEC_LOCK", "").strip().upper()
    if stream_codec_lock == "H264" and codec != "H264":
        fallbacks.append(
            {
                "field": "videoCodec",
                "requested": codec,
                "active": "H264",
                "reason": "server locked to H264 for stable mission play",
            }
        )
        codec = "H264"
    active["videoCodec"] = codec

    display_w, display_h = _configured_display_dims()
    active["displayResolution"] = _format_display_resolution(display_w, display_h)

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
    if audio_encoder == "opus" and audio_quality != "48000":
        fallbacks.append(
            {
                "field": "audioQuality",
                "requested": audio_quality,
                "active": "48000",
                "reason": "Opus uses 48 kHz natively; Pulse capture and transport align to 48 kHz",
            }
        )
        audio_quality = "48000"
    active["audioQuality"] = audio_quality
    native_rate = int(audio_quality)
    active["audioTransportRate"] = native_rate

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
            "videoBitrate": requested.get("videoBitrate", defaults["videoBitrate"]),
            "audioEncoder": requested.get("audioEncoder", defaults["audioEncoder"]),
            "audioQuality": requested.get("audioQuality", defaults["audioQuality"]),
            "audioBitrate": requested.get("audioBitrate", defaults["audioBitrate"]),
            "inputMoveHz": requested.get("inputMoveHz", defaults["inputMoveHz"]),
        },
        "active": active,
        "fallbacks": fallbacks,
    }


def build_helper_env(active: dict, width: int, height: int) -> dict:
    codec = active["videoCodec"]
    # H265_10 is a UI-level codec choice; the helper sees H265 plus a bit depth.
    helper_codec = "H265" if codec == "H265_10" else codec
    bit_depth = "10" if codec == "H265_10" else "8"
    return {
        "ULTRA_VIDEO_CODEC": helper_codec,
        "ULTRA_VIDEO_BIT_DEPTH": bit_depth,
        "ULTRA_VIDEO_BITRATE": str(active["videoBitrate"]),
        "ULTRA_VIDEO_FPS": str(active["videoFps"]),
        "ULTRA_VIDEO_WIDTH": str(width),
        "ULTRA_VIDEO_HEIGHT": str(height),
        "ULTRA_AUDIO_CODEC": active["audioEncoder"],
        "ULTRA_AUDIO_BITRATE": str(active["audioBitrate"]),
        "ULTRA_AUDIO_RATE": active["audioQuality"],
        "ULTRA_AUDIO_TRANSPORT_RATE": active["audioQuality"],
        "DISPLAY": os.environ.get("DISPLAY", ":1"),
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
        self.native_width = VIDEO_WIDTH
        self.native_height = VIDEO_HEIGHT
        self.stream_width = VIDEO_WIDTH
        self.stream_height = VIDEO_HEIGHT

    def set_move_hz(self, move_hz: int) -> None:
        self.move_hz = max(30, min(250, int(move_hz)))

    def set_display_sizes(
        self,
        native_width: int,
        native_height: int,
        stream_width: int,
        stream_height: int,
    ) -> None:
        self.native_width = max(1, int(native_width))
        self.native_height = max(1, int(native_height))
        self.stream_width = max(1, int(stream_width))
        self.stream_height = max(1, int(stream_height))

    def _map_xy(self, event: dict) -> tuple[int, int]:
        """Map stream-space pointer coords onto the native operating display."""
        stream_x = _clamp_int(event.get("x", 0), 0, self.stream_width - 1)
        stream_y = _clamp_int(event.get("y", 0), 0, self.stream_height - 1)
        if (
            self.stream_width == self.native_width
            and self.stream_height == self.native_height
        ):
            return stream_x, stream_y
        native_x = round(
            stream_x * (self.native_width - 1) / max(1, self.stream_width - 1)
        )
        native_y = round(
            stream_y * (self.native_height - 1) / max(1, self.stream_height - 1)
        )
        return (
            _clamp_int(native_x, 0, self.native_width - 1),
            _clamp_int(native_y, 0, self.native_height - 1),
        )

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
            button = _clamp_int(event.get("button", 1), 1, 9)
            if "x" in event and "y" in event:
                x, y = self._map_xy(event)
                self._xdotool(["mousemove", str(x), str(y)])
            self._xdotool(["mousedown", str(button)])
            return
        if kind == "mouseup":
            self._trace_event(event)
            button = _clamp_int(event.get("button", 1), 1, 9)
            if "x" in event and "y" in event:
                x, y = self._map_xy(event)
                self._xdotool(["mousemove", str(x), str(y)])
            self._xdotool(["mouseup", str(button)])
            return
        if kind == "click":
            self._trace_event(event)
            button = _clamp_int(event.get("button", 1), 1, 9)
            if "x" in event and "y" in event:
                x, y = self._map_xy(event)
                self._xdotool(["mousemove", str(x), str(y)])
            self._xdotool(["click", str(button)])
            return
        if kind == "keydown":
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
        display_w, display_h = _configured_display_dims()
        self.helper_env: dict = build_helper_env(defaults, display_w, display_h)
        self.native_width = display_w
        self.native_height = display_h
        self.stream_width = display_w
        self.stream_height = display_h
        self.known_display_dims = (display_w, display_h)
        self.replaced = False
        self.stream_started = False

    async def _send_ready(self, *, reason: str = "start") -> None:
        await self.websocket.send(
            json.dumps(
                {
                    "type": "ready",
                    "reason": reason,
                    "width": self.stream_width,
                    "height": self.stream_height,
                    "nativeWidth": self.native_width,
                    "nativeHeight": self.native_height,
                    "displayResolution": self.active_settings.get("displayResolution"),
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
                            f"{self.active_settings['audioQuality']}Hz"
                        ),
                        "input": f"{self.active_settings['inputMoveHz']}Hz",
                    },
                }
            )
        )

    async def _sync_stream_state(self, *, restart_helper: bool) -> None:
        width, height = _configured_display_dims()
        prev_dims = (self.stream_width, self.stream_height)
        prev_env = dict(self.helper_env)
        next_env = build_helper_env(self.active_settings, width, height)

        self.known_display_dims = (width, height)
        self.native_width = width
        self.native_height = height
        self.stream_width = width
        self.stream_height = height
        self.active_settings["displayResolution"] = _format_display_resolution(width, height)
        self.helper_env = next_env
        self.input.set_display_sizes(width, height, width, height)
        self.input.set_move_hz(self.active_settings["inputMoveHz"])
        if restart_helper:
            if (
                self.helper
                and self.helper.poll() is None
                and (width, height) == prev_dims
                and next_env == prev_env
            ):
                return
            await self.stop_helper("reconfigure")
            await self.start_helper()

    async def _apply_transport_settings(
        self,
        msg: dict,
        *,
        restart_helper: bool,
        become_active: bool,
    ) -> None:
        validated = validate_settings(msg.get("settings"))
        self.requested_settings = validated["requested"]
        self.active_settings = validated["active"]
        self.fallbacks = validated["fallbacks"]

        if become_active:
            await self.become_active()
        should_restart = restart_helper
        await self._sync_stream_state(restart_helper=should_restart)
        self.stream_started = True
        await self._send_ready(reason="reconfigure" if not become_active else "start")

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
        _ensure_game_ini_links()
        if self.helper and self.helper.poll() is None:
            return
        await self.stop_helper("restart")
        try:
            subprocess.run(
                ["pkill", "-f", "/opt/ra2/stream-helper"],
                check=False,
                timeout=5,
            )
        except Exception:
            pass
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
        # Game INI/ddraw sync runs only at gamemd launch (start-game-ultra.sh).
        # Rewriting game-work configs here races map load and freezes the mission.
        _sync_audio_transport(self.active_settings)
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
        if self.replaced:
            await self.stop_helper("helper_eof")
            return
        await self._recover_helper_after_exit("helper_eof")

    async def _recover_helper_after_exit(self, reason: str) -> None:
        await self.stop_helper(reason)
        if not self.stream_started or self.replaced:
            return
        print(
            f"[ultra-gateway] stream helper exited ({reason}); restarting "
            f"(player {PLAYER_ID})",
            flush=True,
        )
        delay = 5.0 if _game_process_running() else 1.0
        await asyncio.sleep(delay)
        if self.replaced or not self.stream_started:
            return
        try:
            await self.start_helper()
            await self._send_ready(reason="helper_restart")
        except Exception as exc:
            print(
                f"[ultra-gateway] stream helper restart failed: {exc}",
                flush=True,
            )

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
            await self._apply_transport_settings(
                msg,
                restart_helper=True,
                become_active=True,
            )
            return
        if msg.get("type") == "reconfigure":
            if not self.stream_started:
                return
            await self._apply_transport_settings(
                msg,
                restart_helper=True,
                become_active=False,
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
