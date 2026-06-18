#!/usr/bin/env python3
"""Ultra-light browser gateway: HTTPS static app + WSS stream on one port."""

import asyncio
import contextlib
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
from urllib.parse import urlparse

from websockets.asyncio.client import connect as ws_connect
from websockets.asyncio.server import serve

GATEWAY_PORT = int(os.environ.get("ULTRA_GATEWAY_PORT", "6080"))
VIDEO_UDP = os.environ.get("ULTRA_VIDEO_UDP", "0") == "1"
WEBRTC_SIGNAL_INTERNAL = int(os.environ.get("WEBRTC_SIGNAL_PORT", "6090"))
TLS_CERT = os.environ.get("TLS_CERT", "/opt/ra2/tls/cert.pem")
TLS_KEY = os.environ.get("TLS_KEY", "/opt/ra2/tls/key.pem")
HELPER = os.environ.get("ULTRA_STREAM_HELPER", "/opt/ra2/stream-helper")
STREAM_CPUSET = os.environ.get("ULTRA_STREAM_CPUSET", "").strip()


def _webrtc_signal_port() -> int:
    player = os.environ.get("PLAYER_ID", "1")
    if player == "2":
        return int(os.environ.get("PLAYER2_WEBRTC_SIGNAL_PORT", "6084"))
    return int(os.environ.get("PLAYER1_WEBRTC_SIGNAL_PORT", "6083"))


def _webrtc_ice_servers() -> list[dict]:
    servers: list[dict] = [
        {"urls": "stun:stun.l.google.com:19302"},
        {"urls": "stun:stun1.l.google.com:19302"},
        {"urls": "stun:stun.cloudflare.com:3478"},
    ]
    turn_urls = os.environ.get("WEBRTC_TURN_URLS", "").strip()
    if not turn_urls:
        return servers
    turn_user = os.environ.get("WEBRTC_TURN_USERNAME", "ra2turn").strip() or "ra2turn"
    turn_pass = os.environ.get("WEBRTC_TURN_PASSWORD", "").strip()
    if not turn_pass:
        return servers
    # Static lt-cred-mech — one iceServer per URL (never bundle urls in an array).
    turn_host = (
        os.environ.get("WEBRTC_ICE_CANDIDATE_HOST", "").strip()
        or os.environ.get("NAS_PUBLIC_HOSTNAME", "").strip()
    )
    for raw in turn_urls.split(","):
        url = raw.strip()
        if not url:
            continue
        servers.append(
            {
                "urls": url,
                "username": turn_user,
                "credential": turn_pass,
            }
        )
    turns_port = os.environ.get("WEBRTC_TURNS_PORT", "5349").strip()
    turns_enabled = os.environ.get("WEBRTC_TURNS_ENABLED", "0").strip() == "1"
    if turns_enabled and turns_port and turn_host:
        servers.append(
            {
                "urls": f"turns:{turn_host}:{turns_port}?transport=tcp",
                "username": turn_user,
                "credential": turn_pass,
            }
        )
    return servers


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
WEBRTC_RUNTIME_BITRATE_FILE = Path(
    os.environ.get(
        "WEBRTC_RUNTIME_BITRATE_FILE",
        str(DIAGNOSTIC_DIR / "webrtc-runtime-bitrate"),
    )
)
WEBRTC_RUNTIME_CODEC_FILE = Path(
    os.environ.get(
        "WEBRTC_RUNTIME_CODEC_FILE",
        str(DIAGNOSTIC_DIR / "webrtc-runtime-codec"),
    )
)
WEBRTC_RUNTIME_FPS_FILE = Path(
    os.environ.get(
        "WEBRTC_RUNTIME_FPS_FILE",
        str(DIAGNOSTIC_DIR / "webrtc-runtime-fps"),
    )
)
DISPLAY = os.environ.get("DISPLAY", ":1")
DISPLAY_ENV = Path(os.environ.get("ULTRA_DISPLAY_ENV", "/home/commander/.ra2/display.env"))
DISPLAY_REVISION = Path(
    os.environ.get("ULTRA_DISPLAY_REVISION", "/home/commander/.ra2/display-revision")
)
ENSURE_INI_LINKS = Path(os.environ.get("ULTRA_ENSURE_INI_LINKS", "/opt/ra2/ensure-game-ini-links.sh"))
GAMES_MANIFEST = Path(os.environ.get("GAMES_MANIFEST", "/opt/ra2/config/games.json"))
VALIDATE_GAME_ID = Path(os.environ.get("VALIDATE_GAME_ID", "/opt/ra2/validate-game-id.sh"))
SECURE_GAME_SELECT = Path(os.environ.get("SECURE_GAME_SELECT", "/opt/ra2/secure-game-select.sh"))
SESSION_STATE_FILE = Path(
    os.environ.get("GAME_SESSION_STATE", "/home/commander/.ra2/session-state")
)
GAME_LAUNCHER_ENABLED = os.environ.get("GAME_LAUNCHER_ENABLED", "0") == "1"
# Native/stream dimensions follow display.env, updated per game via switch-game-display.sh.


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
    return os.environ.get("RESOLUTION", "1024x768").lower()


def _display_dims() -> tuple[int, int]:
    """Native game display size from display.env (updated per game), then RESOLUTION env."""
    saved = _read_display_env()
    res = saved.get("RESOLUTION") or os.environ.get("RESOLUTION", "1024x768")
    res = str(res).lower()
    try:
        width, height = (int(part) for part in res.split("x", 1))
    except ValueError:
        width, height = 1024, 768
    return max(1, width), max(1, height)


def refresh_display_dims() -> tuple[int, int]:
    global VIDEO_WIDTH, VIDEO_HEIGHT
    VIDEO_WIDTH, VIDEO_HEIGHT = _display_dims()
    # Keep gateway process env aligned for helper spawn and diagnostics.
    os.environ["RESOLUTION"] = f"{VIDEO_WIDTH}x{VIDEO_HEIGHT}"
    os.environ["ULTRA_VIDEO_WIDTH"] = str(VIDEO_WIDTH)
    os.environ["ULTRA_VIDEO_HEIGHT"] = str(VIDEO_HEIGHT)
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


def read_session_state() -> dict[str, str]:
    if not SESSION_STATE_FILE.is_file():
        return {"phase": "waiting", "game": ""}
    result: dict[str, str] = {"phase": "waiting", "game": ""}
    try:
        for line in SESSION_STATE_FILE.read_text(encoding="utf-8", errors="replace").splitlines():
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            result[key.strip()] = value.strip()
    except Exception as exc:
        print(f"[ultra-gateway] session state unreadable: {exc}", flush=True)
    return result


def _game_title(game_id: str) -> str:
    if not game_id or not GAMES_MANIFEST.is_file():
        return game_id
    try:
        manifest = json.loads(GAMES_MANIFEST.read_text(encoding="utf-8"))
        profile = manifest.get(game_id, {})
        if isinstance(profile, dict):
            return str(profile.get("title", game_id))
    except Exception:
        pass
    return game_id


def get_current_game_session() -> dict[str, str | None]:
    state = read_session_state()
    phase = str(state.get("phase", "waiting") or "waiting")
    game_id = str(state.get("game", "") or "")
    if not game_id:
        return {"phase": phase, "id": None, "title": None}
    return {"phase": phase, "id": game_id, "title": _game_title(game_id)}


async def wait_for_game_running(game_id: str, timeout: float = 120.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        session = get_current_game_session()
        if session.get("id") == game_id and session.get("phase") == "running":
            return True
        await asyncio.sleep(0.25)
    return False


def get_available_games() -> list[dict[str, str]]:
    if not GAMES_MANIFEST.is_file():
        return []
    try:
        manifest = json.loads(GAMES_MANIFEST.read_text(encoding="utf-8"))
    except Exception as exc:
        print(f"[ultra-gateway] games manifest unreadable: {exc}", flush=True)
        return []
    games: list[dict[str, str]] = []
    for game_id, profile in manifest.items():
        if not isinstance(profile, dict):
            continue
        assets = Path(str(profile.get("assetsPath", "")))
        exe_name = str(profile.get("gameExe", ""))
        if not exe_name:
            continue
        if (assets / exe_name).is_file():
            games.append({"id": str(game_id), "title": str(profile.get("title", game_id))})
    return games


async def authorize_game_selection(game_id: str) -> tuple[bool, str]:
    game_id = str(game_id or "").strip()
    if not game_id:
        return False, "missing game id"
    if not VALIDATE_GAME_ID.is_file() or not SECURE_GAME_SELECT.is_file():
        return False, "game selection unavailable"

    current = get_current_game_session()
    if current.get("phase") == "running" and current.get("id") == game_id:
        return True, game_id

    validate = await asyncio.create_subprocess_exec(
        "/bin/sh",
        str(VALIDATE_GAME_ID),
        game_id,
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.DEVNULL,
    )
    await validate.wait()
    if validate.returncode != 0:
        return False, "invalid game id"

    switching = current.get("phase") == "running" and current.get("id") not in {None, "", game_id}

    select = await asyncio.create_subprocess_exec(
        "/bin/sh",
        str(SECURE_GAME_SELECT),
        game_id,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    _stdout, stderr = await select.communicate()
    if select.returncode != 0:
        detail = stderr.decode("utf-8", errors="replace").strip() or "selection failed"
        return False, detail

    if not await wait_for_game_running(game_id, timeout=120.0):
        if switching:
            return False, "game switch timed out"
        return False, "game start timed out"

    return True, game_id


VIDEO_WIDTH, VIDEO_HEIGHT = _display_dims()

# 480p / 600p (SVGA) / 768p (XGA) / 720p / 1080p tiers (4:3). Exposed to Wine via configure-display-modes.sh.
RESOLUTION_TIERS: dict[str, tuple[int, int]] = {
    "480p": (640, 480),
    "600p": (800, 600),
    "768p": (1024, 768),
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
ALLOWED_VIDEO_FPS = frozenset({20, 24, 30})
VIDEO_QUALITY_PRESETS = {
    "low": {"fps": 20},
    "balanced": {"fps": 24},
    "sharp": {"fps": MAX_VIDEO_FPS},
}
ALLOWED_VIDEO_QUALITY = frozenset(VIDEO_QUALITY_PRESETS)
ALLOWED_VIDEO_BITRATES = frozenset({300000, 450000, 600000, 900000, 1200000, 1600000, 2000000, 3500000})
ALLOWED_VIDEO_RESOLUTIONS = tuple(
    f"{width}x{height}" for width, height in GAME_DISPLAY_MODES
)
ALLOWED_VIDEO_CODECS = ("H264", "H265", "H265_10")
ALLOWED_AUDIO_QUALITY = frozenset({"44100", "48000"})
ALLOWED_AUDIO_BITRATES = frozenset({64000, 96000, 128000})
ALLOWED_INPUT_HZ = frozenset({60, 125, 200})
ALLOWED_AUDIO_ENCODERS = frozenset({"opus", "pcm"})
VIDEO_TRANSPORT_FIELDS = ("videoQuality", "videoCodec", "videoBitrate", "videoFps")
AUDIO_TRANSPORT_FIELDS = ("audioEncoder", "audioQuality", "audioBitrate")
STREAM_TRANSPORT_FIELDS = VIDEO_TRANSPORT_FIELDS + AUDIO_TRANSPORT_FIELDS + ("inputMoveHz",)
INPUT_MESSAGE_TYPES = frozenset(
    {
        "mousemove",
        "mousedown",
        "mouseup",
        "click",
        "keydown",
        "keyup",
        "keyup_all",
        "wheel",
    }
)
GAME_WINDOW_PATTERNS: dict[str, tuple[str, ...]] = {
    "ra2": ("Yuri's Revenge", "Red Alert 2", "Red Alert"),
    "starcraft": ("StarCraft", "Brood War"),
    "aoe2": ("Age of Empires II", "EMPIRES2"),
}
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
SPECTATOR_SESSIONS: set["StreamSession"] = set()
ACTIVE_SESSION_LOCK = asyncio.Lock()


def _websocket_open(websocket) -> bool:
    try:
        from websockets.protocol import State

        return websocket.state is State.OPEN
    except Exception:
        return True


async def prune_stale_sessions() -> None:
    """Drop controller/spectator slots whose WebSocket is no longer open."""
    async with ACTIVE_SESSION_LOCK:
        controller = ACTIVE_SESSION
        spectators = list(SPECTATOR_SESSIONS)
    if controller and not _websocket_open(controller.websocket):
        print(
            f"[ultra-gateway] pruning stale controller (socket closed) "
            f"(player {PLAYER_ID})",
            flush=True,
        )
        await controller.release_controller_slot("stale socket pruned")
    stale_spectators = [
        session for session in spectators if not _websocket_open(session.websocket)
    ]
    if stale_spectators:
        async with ACTIVE_SESSION_LOCK:
            for session in stale_spectators:
                SPECTATOR_SESSIONS.discard(session)


def session_presence() -> dict[str, object]:
    controller = ACTIVE_SESSION
    if controller and not _websocket_open(controller.websocket):
        controller = None
    streaming = bool(controller and controller.stream_started)
    return {
        "controllerActive": controller is not None,
        "controllerStreaming": streaming,
        "spectatorCount": len(SPECTATOR_SESSIONS),
    }

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
    # Exact tier sizes plus boot RESOLUTION (default 1024x768). Ignore transient
    # in-game sizes during map load so we do not restart Xvfb mid-session.
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
    """Current display size from display.env / RESOLUTION (never live X11 or INI)."""
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


def _write_webrtc_runtime_bitrate(bitrate: int) -> None:
    WEBRTC_RUNTIME_BITRATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    WEBRTC_RUNTIME_BITRATE_FILE.write_text(f"{int(bitrate)}\n", encoding="utf-8")


def _write_webrtc_runtime_codec(codec: str) -> None:
    WEBRTC_RUNTIME_CODEC_FILE.parent.mkdir(parents=True, exist_ok=True)
    WEBRTC_RUNTIME_CODEC_FILE.write_text(f"{codec.strip().upper()}\n", encoding="utf-8")


def _write_webrtc_runtime_fps(fps: int) -> None:
    WEBRTC_RUNTIME_FPS_FILE.parent.mkdir(parents=True, exist_ok=True)
    WEBRTC_RUNTIME_FPS_FILE.write_text(f"{int(fps)}\n", encoding="utf-8")


async def _restart_webrtc_media(reason: str) -> None:
    if not VIDEO_UDP or os.environ.get("WEBRTC_ENABLED", "0") != "1":
        return
    print(
        f"[ultra-gateway] restarting webrtc-media reason={reason} "
        f"(player {PLAYER_ID})",
        flush=True,
    )
    try:
        result = await asyncio.to_thread(
            subprocess.run,
            ["supervisorctl", "-c", "/opt/ra2/supervisord.conf", "restart", "webrtc-media"],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode != 0:
            detail = (result.stderr or result.stdout or "").strip()
            print(
                f"[ultra-gateway] webrtc-media restart failed: {detail or result.returncode}",
                flush=True,
            )
    except Exception as exc:
        print(f"[ultra-gateway] webrtc-media restart error: {exc}", flush=True)


def default_settings() -> dict:
    quality = "balanced"
    preset = VIDEO_QUALITY_PRESETS[quality]
    display_w, display_h = _configured_display_dims()
    settings = {
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
    return settings


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
                "videoFps": sorted(ALLOWED_VIDEO_FPS),
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
        requested_fps = int(requested.get("videoFps", active["videoFps"]))
    except (TypeError, ValueError):
        requested_fps = active["videoFps"]
    if requested_fps not in ALLOWED_VIDEO_FPS:
        fallbacks.append(
            {
                "field": "videoFps",
                "requested": requested_fps,
                "active": active["videoFps"],
                "reason": "unsupported frame rate",
            }
        )
    else:
        active["videoFps"] = requested_fps

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

    requested_payload = {
        "videoQuality": requested.get("videoQuality", defaults["videoQuality"]),
        "videoCodec": requested.get("videoCodec", defaults["videoCodec"]),
        "videoBitrate": requested.get("videoBitrate", defaults["videoBitrate"]),
        "videoFps": requested.get("videoFps", defaults["videoFps"]),
        "audioEncoder": requested.get("audioEncoder", defaults["audioEncoder"]),
        "audioQuality": requested.get("audioQuality", defaults["audioQuality"]),
        "audioBitrate": requested.get("audioBitrate", defaults["audioBitrate"]),
        "inputMoveHz": requested.get("inputMoveHz", defaults["inputMoveHz"]),
    }

    return {
        "requested": requested_payload,
        "active": active,
        "fallbacks": fallbacks,
    }


def build_helper_env(
    active: dict, width: int, height: int, *, wss_video: Optional[bool] = None
) -> dict:
    codec = active["videoCodec"]
    # H265_10 is a UI-level codec choice; the helper sees H265 plus a bit depth.
    helper_codec = "H265" if codec == "H265_10" else codec
    bit_depth = "10" if codec == "H265_10" else "8"
    if wss_video is None:
        # Keep WSS video on during UDP/WebRTC negotiation so the browser has
        # picture immediately and can fall back without a blank gap.
        wss_video = True
    env = {
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
        "ULTRA_WSS_VIDEO": "1" if wss_video else "0",
    }
    if VIDEO_UDP:
        env["ULTRA_VIDEO_UDP"] = "1"
    return env


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
    rel = urlparse(path).path.lstrip("/") or "index.html"
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
        game_id = str(get_current_game_session().get("id") or "")
        patterns = GAME_WINDOW_PATTERNS.get(game_id, GAME_WINDOW_PATTERNS["ra2"])
        for pattern in patterns:
            try:
                result = subprocess.run(
                    ["xdotool", "search", "--name", pattern, "windowactivate", "%@"],
                    env=env,
                    check=False,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=2,
                )
                if result.returncode == 0:
                    return
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
        self.role = "pending"
        self._transport_apply_lock = asyncio.Lock()

    async def _run_transport_settings(
        self,
        msg: dict,
        *,
        restart_helper: bool,
        become_active: bool,
    ) -> None:
        async with self._transport_apply_lock:
            try:
                await self._apply_transport_settings(
                    msg,
                    restart_helper=restart_helper,
                    become_active=become_active,
                )
            except Exception as exc:
                print(
                    f"[ultra-gateway] transport settings failed: {exc} (player {PLAYER_ID})",
                    flush=True,
                )

    def _mirror_controller_state(self, controller: "StreamSession") -> None:
        self.active_settings = dict(controller.active_settings)
        self.requested_settings = dict(controller.requested_settings)
        self.fallbacks = list(controller.fallbacks)
        self.native_width = controller.native_width
        self.native_height = controller.native_height
        self.stream_width = controller.stream_width
        self.stream_height = controller.stream_height
        self.known_display_dims = controller.known_display_dims
        self.helper_env = dict(controller.helper_env)

    async def _broadcast_stream_payload(self, line: str) -> None:
        if line.startswith('{"type":"video"'):
            self.frames_sent += 1
        recipients = [self]
        async with ACTIVE_SESSION_LOCK:
            recipients.extend(list(SPECTATOR_SESSIONS))
        stale: list[StreamSession] = []
        for session in recipients:
            if session is self:
                target = session
            else:
                target = session
            try:
                await target.websocket.send(line)
            except Exception:
                stale.append(session)
        if stale:
            async with ACTIVE_SESSION_LOCK:
                for session in stale:
                    SPECTATOR_SESSIONS.discard(session)

    async def _sync_spectators_ready(self, *, reason: str) -> None:
        async with ACTIVE_SESSION_LOCK:
            spectators = list(SPECTATOR_SESSIONS)
        for session in spectators:
            session._mirror_controller_state(self)
            session.stream_started = True
            try:
                await session._send_ready(reason=reason)
            except Exception:
                async with ACTIVE_SESSION_LOCK:
                    SPECTATOR_SESSIONS.discard(session)

    async def _notify_spectators_controller_left(self) -> None:
        payload = json.dumps(
            {
                "type": "controllerLeft",
                **session_presence(),
            }
        )
        async with ACTIVE_SESSION_LOCK:
            spectators = list(SPECTATOR_SESSIONS)
        stale: list[StreamSession] = []
        for session in spectators:
            session.stream_started = False
            try:
                await session.websocket.send(payload)
            except Exception:
                stale.append(session)
        if stale:
            async with ACTIVE_SESSION_LOCK:
                for session in stale:
                    SPECTATOR_SESSIONS.discard(session)

    async def try_claim_controller(self) -> bool:
        global ACTIVE_SESSION
        async with ACTIVE_SESSION_LOCK:
            if ACTIVE_SESSION and ACTIVE_SESSION is not self:
                return False
            ACTIVE_SESSION = self
            self.role = "controller"
            return True

    async def release_controller_slot(self, reason: str = "released") -> None:
        global ACTIVE_SESSION
        was_controller = self.role == "controller"
        async with ACTIVE_SESSION_LOCK:
            if ACTIVE_SESSION is self:
                ACTIVE_SESSION = None
            SPECTATOR_SESSIONS.discard(self)
            self.replaced = True
        if was_controller:
            with contextlib.suppress(Exception):
                await self._notify_spectators_controller_left()
            with contextlib.suppress(Exception):
                await self.stop_helper(reason)
        self.stream_started = False
        self.role = "pending"

    async def force_takeover_controller(self, reason: str = "controller takeover") -> bool:
        """Evict the current controller so this session can claim control."""
        async with ACTIVE_SESSION_LOCK:
            controller = ACTIVE_SESSION
            if not controller or controller is self:
                return False
        await controller.release_controller_slot(reason)
        with contextlib.suppress(Exception):
            await controller.websocket.close(code=4001, reason=reason)
        print(
            f"[ultra-gateway] controller takeover: replaced stale session "
            f"(player {PLAYER_ID})",
            flush=True,
        )
        return True

    async def attach_as_spectator(self) -> None:
        global ACTIVE_SESSION
        async with ACTIVE_SESSION_LOCK:
            if ACTIVE_SESSION is self:
                self.role = "controller"
            else:
                self.role = "spectator"
                SPECTATOR_SESSIONS.add(self)
            controller = ACTIVE_SESSION
        if controller and controller.stream_started:
            self._mirror_controller_state(controller)
            self.stream_started = True
            await self._send_ready(reason="watch")
            return
        await self.websocket.send(
            json.dumps(
                {
                    "type": "waitingForController",
                    **session_presence(),
                    "currentGame": get_current_game_session() if GAME_LAUNCHER_ENABLED else None,
                }
            )
        )

    async def _send_role(self) -> None:
        await self.websocket.send(
            json.dumps(
                {
                    "type": "role",
                    "role": self.role,
                    **session_presence(),
                }
            )
        )

    async def _send_ready(self, *, reason: str = "start") -> None:
        await self.websocket.send(
            json.dumps(
                {
                    "type": "ready",
                    "reason": reason,
                    "role": self.role,
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
                    "webrtcIceServers": _webrtc_ice_servers() if VIDEO_UDP else None,
                    **session_presence(),
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
        wss_video = self.helper_env.get("ULTRA_WSS_VIDEO", "1") == "1"
        next_env = build_helper_env(
            self.active_settings, width, height, wss_video=wss_video
        )

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

    async def _set_video_path(self, path: str) -> None:
        want_wss = path == "wss"
        current_wss = self.helper_env.get("ULTRA_WSS_VIDEO", "1") == "1"
        if want_wss == current_wss:
            return
        width, height = self.stream_width, self.stream_height
        self.helper_env = build_helper_env(
            self.active_settings, width, height, wss_video=want_wss
        )
        label = "wss" if want_wss else "webrtc"
        print(
            f"[ultra-gateway] video path -> {label} (player {PLAYER_ID})",
            flush=True,
        )
        if self.stream_started:
            await self.stop_helper("video_path")
            await self.start_helper()

    async def _apply_transport_settings(
        self,
        msg: dict,
        *,
        restart_helper: bool,
        become_active: bool,
    ) -> None:
        prev_active = dict(self.active_settings)
        validated = validate_settings(msg.get("settings"))
        self.requested_settings = validated["requested"]
        self.active_settings = validated["active"]
        self.fallbacks = validated["fallbacks"]

        if become_active:
            if not await self.try_claim_controller():
                await self.websocket.send(
                    json.dumps(
                        {
                            "type": "controllerBusy",
                            **session_presence(),
                        }
                    )
                )
                return
        video_changed = any(
            prev_active.get(field) != self.active_settings.get(field)
            for field in VIDEO_TRANSPORT_FIELDS
        )
        audio_changed = any(
            prev_active.get(field) != self.active_settings.get(field)
            for field in AUDIO_TRANSPORT_FIELDS
        )
        input_changed = (
            prev_active.get("inputMoveHz") != self.active_settings.get("inputMoveHz")
        )
        if input_changed:
            self.input.set_move_hz(self.active_settings["inputMoveHz"])

        wss_video = self.helper_env.get("ULTRA_WSS_VIDEO", "1") == "1"
        helper_needs_restart = audio_changed or (video_changed and (not VIDEO_UDP or wss_video))
        should_restart = restart_helper and helper_needs_restart
        await self._sync_stream_state(restart_helper=should_restart)
        if not self.helper or self.helper.poll() is not None:
            await self.start_helper()
        if VIDEO_UDP and video_changed:
            _write_webrtc_runtime_bitrate(int(self.active_settings["videoBitrate"]))
            _write_webrtc_runtime_fps(int(self.active_settings["videoFps"]))
            _write_webrtc_runtime_codec(str(self.active_settings["videoCodec"]))
            if become_active:
                reason = "stream_start"
            elif prev_active.get("videoCodec") != self.active_settings.get("videoCodec"):
                reason = "video_codec"
            elif prev_active.get("videoBitrate") != self.active_settings.get("videoBitrate"):
                reason = "video_bitrate"
            elif prev_active.get("videoFps") != self.active_settings.get("videoFps"):
                reason = "video_fps"
            else:
                reason = "video_settings"
            await _restart_webrtc_media(reason)
        self.stream_started = True
        reason = "reconfigure" if not become_active else "start"
        await self._send_ready(reason=reason)
        if self.role == "controller":
            await self._sync_spectators_ready(reason=reason)

    async def become_active(self) -> None:
        await self.try_claim_controller()

    async def clear_active(self) -> None:
        global ACTIVE_SESSION
        async with ACTIVE_SESSION_LOCK:
            if ACTIVE_SESSION is self:
                ACTIVE_SESSION = None
            SPECTATOR_SESSIONS.discard(self)

    async def cleanup_disconnect(self) -> None:
        if self.role == "controller":
            await self._notify_spectators_controller_left()
            await self.stop_helper("disconnect")
        await self.clear_active()

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
                pass
            await self._broadcast_stream_payload(line)
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
            if self.role == "controller":
                await self._sync_spectators_ready(reason="helper_restart")
        except Exception as exc:
            print(
                f"[ultra-gateway] stream helper restart failed: {exc}",
                flush=True,
            )

    async def handle_client_message(self, msg: dict) -> None:
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
        if msg.get("type") == "selectGame":
            game_id = str(msg.get("game", "")).strip()
            async with ACTIVE_SESSION_LOCK:
                controller = ACTIVE_SESSION
            if controller and controller is not self:
                await self.force_takeover_controller("superseded by reconnect")
            if not await self.try_claim_controller():
                await self.websocket.send(
                    json.dumps(
                        {
                            "type": "selectGameResult",
                            "ok": False,
                            "game": None,
                            "error": "Another player is in control. Use Watch stream to view.",
                            "currentGame": get_current_game_session(),
                            **session_presence(),
                        }
                    )
                )
                return
            prior = get_current_game_session()
            ok, detail = await authorize_game_selection(game_id)
            current = get_current_game_session()
            await self.websocket.send(
                json.dumps(
                    {
                        "type": "selectGameResult",
                        "ok": ok,
                        "game": detail if ok else None,
                        "error": None if ok else detail,
                        "currentGame": current,
                        "role": self.role,
                        **session_presence(),
                        "switched": ok
                        and prior.get("phase") == "running"
                        and prior.get("id") not in {None, "", detail},
                    }
                )
            )
            if ok:
                print(
                    f"[ultra-gateway] game selected: {detail} (player {PLAYER_ID}, controller)",
                    flush=True,
                )
            else:
                print(
                    f"[ultra-gateway] game selection rejected: {detail} (player {PLAYER_ID})",
                    flush=True,
                )
            return
        if msg.get("type") == "watch":
            await self.attach_as_spectator()
            await self._send_role()
            return
        if msg.get("type") == "start":
            if self.role == "spectator":
                return
            await self._run_transport_settings(
                msg,
                restart_helper=True,
                become_active=True,
            )
            return
        if msg.get("type") == "reconfigure":
            if self.role != "controller" or not self.stream_started:
                return
            asyncio.create_task(
                self._run_transport_settings(
                    msg,
                    restart_helper=True,
                    become_active=False,
                )
            )
            return
        if msg.get("type") == "videoPath":
            if self.role != "controller" or not self.stream_started or not VIDEO_UDP:
                return
            path = str(msg.get("path", "")).strip().lower()
            if path not in {"wss", "webrtc"}:
                return
            await self._set_video_path(path)
            return
        if msg.get("type") == "stop":
            if self.role != "controller":
                return
            self.input.release_all_keys()
            await self.stop_helper("client_stop")
            return

def process_request(connection, request):
    path = request.path.split("?", 1)[0]
    if path == "/turn-ice.json" and VIDEO_UDP:
        payload = json.dumps({"iceServers": _webrtc_ice_servers()})
        response = connection.respond(HTTPStatus.OK, payload)
        response.headers["Content-Type"] = "application/json"
        response.headers["Cache-Control"] = "no-store"
        return response
    served = _static_body(request.path)
    if served is None:
        return None
    content_type, body = served
    response = connection.respond(HTTPStatus.OK, body.decode("utf-8"))
    response.headers["Content-Type"] = content_type
    response.headers["Cache-Control"] = "no-store"
    return response


async def webrtc_signal_proxy(client_ws) -> None:
    """Bridge browser WebRTC signaling on the play port to the in-container bridge."""
    use_tls = os.environ.get("WEBRTC_SIGNAL_TLS", "0") == "1"
    scheme = "wss" if use_tls else "ws"
    target = f"{scheme}://127.0.0.1:{WEBRTC_SIGNAL_INTERNAL}"
    print(f"[ultra-gateway] webrtc-signal proxy -> {target} (player {PLAYER_ID})", flush=True)
    ssl_ctx = None
    if use_tls:
        ssl_ctx = ssl.create_default_context()
        ssl_ctx.check_hostname = False
        ssl_ctx.verify_mode = ssl.CERT_NONE
    try:
        async with ws_connect(target, ssl=ssl_ctx, open_timeout=10) as upstream:
            async def forward_client() -> None:
                async for message in client_ws:
                    await upstream.send(message)

            async def forward_upstream() -> None:
                async for message in upstream:
                    await client_ws.send(message)

            forward_tasks = (
                asyncio.create_task(forward_client()),
                asyncio.create_task(forward_upstream()),
            )
            await asyncio.gather(*forward_tasks)
    except Exception as exc:
        print(f"[ultra-gateway] webrtc-signal proxy failed: {exc}", flush=True)
        with contextlib.suppress(Exception):
            await client_ws.close(1011, "webrtc signal proxy failed")


async def stream_handler(websocket) -> None:
    session = StreamSession(websocket)
    print(f"[ultra-gateway] client connected (player {PLAYER_ID})", flush=True)
    await prune_stale_sessions()
    try:
        await websocket.send(
            json.dumps(
                {
                    "type": "hello",
                    "player": PLAYER_ID,
                    "codec": os.environ.get("ULTRA_VIDEO_CODEC", "H264"),
                    "fps": int(os.environ.get("ULTRA_VIDEO_FPS", "24")),
                    "videoTransport": "udp" if VIDEO_UDP else "wss",
                    "webrtcSignalPort": _webrtc_signal_port() if VIDEO_UDP else None,
                    "webrtcIceServers": _webrtc_ice_servers() if VIDEO_UDP else None,
                    "defaults": default_settings(),
                    "available": get_available_options(),
                    "gameLauncherEnabled": GAME_LAUNCHER_ENABLED,
                    "availableGames": get_available_games() if GAME_LAUNCHER_ENABLED else [],
                    "currentGame": get_current_game_session() if GAME_LAUNCHER_ENABLED else None,
                    **session_presence(),
                }
            )
        )
        async for raw in websocket:
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if msg.get("type") in INPUT_MESSAGE_TYPES:
                if session.role == "controller":
                    session.input.handle(msg)
                continue
            await session.handle_client_message(msg)
    finally:
        if session.role == "controller":
            session.input.release_all_keys()
        await session.cleanup_disconnect()
        elapsed = time.monotonic() - session.connected_at
        print(
            f"[ultra-gateway] client disconnected frames={session.frames_sent} "
            f"elapsed={elapsed:.1f}s (player {PLAYER_ID})",
            flush=True,
        )


async def watch_display_revision() -> None:
    last_stamp = ""
    while True:
        await asyncio.sleep(0.5)
        try:
            stamp = DISPLAY_REVISION.read_text(encoding="utf-8", errors="replace").strip()
        except OSError:
            continue
        if not stamp or stamp == last_stamp:
            continue
        last_stamp = stamp
        async with ACTIVE_SESSION_LOCK:
            controller = ACTIVE_SESSION
        if not controller or not controller.stream_started:
            continue
        print(
            f"[ultra-gateway] display revision {stamp}; reconfiguring stream "
            f"(player {PLAYER_ID})",
            flush=True,
        )
        try:
            refresh_display_dims()
            await controller._sync_stream_state(restart_helper=True)
            await controller._send_ready(reason="display_change")
            await controller._sync_spectators_ready(reason="display_change")
        except Exception as exc:
            print(f"[ultra-gateway] display refresh failed: {exc}", flush=True)


async def gateway_handler(websocket) -> None:
    path = websocket.request.path.rstrip("/") or "/"
    if path == "/webrtc-signal":
        if not VIDEO_UDP or os.environ.get("WEBRTC_ENABLED", "0") != "1":
            await websocket.close(1008, "UDP video disabled")
            return
        await webrtc_signal_proxy(websocket)
        return
    if path not in {"/stream"}:
        await websocket.close(1008, "connect to /stream or /webrtc-signal")
        return
    await stream_handler(websocket)


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
        gateway_handler,
        "0.0.0.0",
        GATEWAY_PORT,
        ssl=ssl_ctx,
        process_request=process_request,
        max_size=16 * 1024 * 1024,
        ping_interval=20,
        ping_timeout=60,
    ):
        watcher = asyncio.create_task(watch_display_revision())
        try:
            await asyncio.Future()
        finally:
            watcher.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await watcher


if __name__ == "__main__":
    asyncio.run(main())
