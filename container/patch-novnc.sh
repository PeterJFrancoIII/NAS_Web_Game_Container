#!/usr/bin/env bash
set -euo pipefail

NOVNC_DIR="${1:-/opt/novnc}"
AUDIO_PLUGIN_URL="${AUDIO_PLUGIN_URL:-https://raw.githubusercontent.com/me-asri/noVNC-audio-plugin/main/audio-plugin.js}"
AUDIO_BUFFER_MIN_REMAIN="${AUDIO_BUFFER_MIN_REMAIN:-3}"
AUDIO_DRIFT_CHECK_INTERVAL_MS="${AUDIO_DRIFT_CHECK_INTERVAL_MS:-2000}"
AUDIO_DRIFT_MAX_TOLERANCE="${AUDIO_DRIFT_MAX_TOLERANCE:-0.5}"
AUDIO_TARGET_LATENCY="${AUDIO_TARGET_LATENCY:-1.0}"
AUDIO_MAX_PLAYBACK_RATE_DELTA="${AUDIO_MAX_PLAYBACK_RATE_DELTA:-0.03}"
LATENCY_OVERLAY_ENABLED="${LATENCY_OVERLAY_ENABLED:-1}"

if [ ! -f "${NOVNC_DIR}/audio-plugin.js" ] || [ "${AUDIO_PLUGIN_REFRESH:-0}" = "1" ]; then
  curl -fsSL -o "${NOVNC_DIR}/audio-plugin.js" "${AUDIO_PLUGIN_URL}"
fi

if ! grep -q 'audio-plugin.js' "${NOVNC_DIR}/vnc.html"; then
  sed -i 's|</head>|  <script type="module" crossorigin="anonymous" src="audio-plugin.js"></script>\n</head>|' "${NOVNC_DIR}/vnc.html"
fi

if [ "${LATENCY_OVERLAY_ENABLED}" = "1" ]; then
  cp /opt/ra2/latency-overlay.js "${NOVNC_DIR}/latency-overlay.js"
  if ! grep -q 'latency-overlay.js' "${NOVNC_DIR}/vnc.html"; then
    sed -i 's|</head>|  <script defer src="latency-overlay.js"></script>\n</head>|' "${NOVNC_DIR}/vnc.html"
  fi
fi

cp /opt/ra2/cursor-lock.js "${NOVNC_DIR}/cursor-lock.js"
if ! grep -q 'cursor-lock.js' "${NOVNC_DIR}/vnc.html"; then
  sed -i 's|</head>|  <script defer src="cursor-lock.js"></script>\n</head>|' "${NOVNC_DIR}/vnc.html"
fi

# Route VNC and audio over the same websockify token listener.
sed -i "s/UI.initSetting('path', 'websockify')/UI.initSetting('path', 'websockify?token=vnc')/" "${NOVNC_DIR}/app/ui.js"
sed -i 's/UI.initSetting("path", "websockify")/UI.initSetting("path", "websockify?token=vnc")/' "${NOVNC_DIR}/app/ui.js"

# Favor smooth playback on the DS225+ over bandwidth savings. Tight compression
# is CPU-heavy in x11vnc; LAN bandwidth is cheaper than dropped frames/audio.
sed -i "s/UI.initSetting('compression', [0-9][0-9]*)/UI.initSetting('compression', 0)/" "${NOVNC_DIR}/app/ui.js"
sed -i 's/UI.initSetting("compression", [0-9][0-9]*)/UI.initSetting("compression", 0)/' "${NOVNC_DIR}/app/ui.js"
sed -i "s/UI.initSetting('quality', [0-9][0-9]*)/UI.initSetting('quality', 6)/" "${NOVNC_DIR}/app/ui.js"
sed -i 's/UI.initSetting("quality", [0-9][0-9]*)/UI.initSetting("quality", 6)/' "${NOVNC_DIR}/app/ui.js"
sed -i "s/UI.initSetting('resize', '[^']*')/UI.initSetting('resize', 'remote')/" "${NOVNC_DIR}/app/ui.js"
sed -i 's/UI.initSetting("resize", "[^"]*")/UI.initSetting("resize", "remote")/' "${NOVNC_DIR}/app/ui.js"

# Enable browser audio by default after connect.
sed -i "s/'audio_enabled', false/'audio_enabled', true/" "${NOVNC_DIR}/audio-plugin.js"
sed -i "s/}, '48000', 'Audio sample rate/}, '44100', 'Audio sample rate/" "${NOVNC_DIR}/audio-plugin.js"

# Keep audio roughly near the noVNC live edge, but favor smooth playback over
# perfect sync. Too little browser-side cushion causes audible underruns.
sed -i "s/static #BUFFER_MIN_REMAIN = [0-9.]*;/static #BUFFER_MIN_REMAIN = ${AUDIO_BUFFER_MIN_REMAIN};/" "${NOVNC_DIR}/audio-plugin.js"
sed -i "s/static #DRIFT_CHECK_INTERVAL = [0-9]*;/static #DRIFT_CHECK_INTERVAL = ${AUDIO_DRIFT_CHECK_INTERVAL_MS};/" "${NOVNC_DIR}/audio-plugin.js"
sed -i "s/static #DRIFT_MAX_TOLERANCE = [0-9.]*;/static #DRIFT_MAX_TOLERANCE = ${AUDIO_DRIFT_MAX_TOLERANCE};/" "${NOVNC_DIR}/audio-plugin.js"

python - "${NOVNC_DIR}/audio-plugin.js" <<'PY'
from pathlib import Path
import os
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
target_latency = os.environ.get("AUDIO_TARGET_LATENCY", "0.35")
max_playback_rate_delta = os.environ.get("AUDIO_MAX_PLAYBACK_RATE_DELTA", "0.06")
text = re.sub(
    r"(    static #DRIFT_MAX_TOLERANCE = [0-9.]+;\n)(?:    static #TARGET_LATENCY = [0-9.]+;\n)?(?:    static #MAX_PLAYBACK_RATE_DELTA = [0-9.]+;\n)?",
    r"\1    static #TARGET_LATENCY = AUDIO_TARGET_LATENCY_PLACEHOLDER;\n    static #MAX_PLAYBACK_RATE_DELTA = AUDIO_MAX_PLAYBACK_RATE_DELTA_PLACEHOLDER;\n",
    text,
)
text = text.replace("AUDIO_TARGET_LATENCY_PLACEHOLDER", target_latency)
text = text.replace("AUDIO_MAX_PLAYBACK_RATE_DELTA_PLACEHOLDER", max_playback_rate_delta)
text = re.sub(
    r"    #onPlayCallback = \(event\) => \{\n        const elem = event\.target;\n\n        // Make sure we're always playing the live edge of the stream\n        // Mostly necessary if some external entity decided to pause the media\n        if \(this\.sourceBuffer\.buffered\.length > 0\) \{\n            elem\.currentTime = this\.sourceBuffer\.buffered\.end\(0\);\n        \}\n\n        // Workaround: Use a slightly faster playback speed to minimize drift\n        elem\.playbackRate = 1\.003;\n    \};",
    """    #onPlayCallback = (event) => {
        const elem = event.target;

        // Start close to the live edge, but keep enough cushion to avoid MSE
        // underruns. Seeking to the absolute end causes audible/video hitches.
        if (this.sourceBuffer.buffered.length > 0) {
            const bufferEnd = this.sourceBuffer.buffered.end(0);
            elem.currentTime = Math.max(0, bufferEnd - MediaSourcePlayer.#TARGET_LATENCY);
        }

        elem.playbackRate = 1;
    };""",
    text,
)
text = text.replace(
    "                this.#driftCheckTimer = setInterval(() => this.#checkDrift(), MediaSourcePlayer.#DRIFT_CHECK_INTERVAL);",
    """                if (MediaSourcePlayer.#DRIFT_CHECK_INTERVAL > 0) {
                    this.#driftCheckTimer = setInterval(() => this.#checkDrift(), MediaSourcePlayer.#DRIFT_CHECK_INTERVAL);
                }""",
)
replacement = """    #checkDrift() {
        if (this.#attachedEl.paused) {
            return;
        }
        if (this.sourceBuffer.buffered.length == 0) {
            return;
        }

        const bufferEnd = this.sourceBuffer.buffered.end(0);
        const targetLatency = MediaSourcePlayer.#TARGET_LATENCY;
        const drift = bufferEnd - this.#attachedEl.currentTime;
        const error = drift - targetLatency;

        // Correct drift by nudging playback speed instead of seeking. This keeps
        // audio near the live video edge without causing periodic freezes.
        if (Math.abs(error) <= MediaSourcePlayer.#DRIFT_MAX_TOLERANCE) {
            this.#attachedEl.playbackRate = 1;
            return;
        }

        const correction = Math.max(
            -MediaSourcePlayer.#MAX_PLAYBACK_RATE_DELTA,
            Math.min(MediaSourcePlayer.#MAX_PLAYBACK_RATE_DELTA, error * 0.08),
        );
        this.#attachedEl.playbackRate = 1 + correction;
    }"""

text = re.sub(
    r"    #checkDrift\(\) \{\n        if \(this\.\#attachedEl\.paused\) \{\n            return;\n        \}\n        if \(this\.sourceBuffer\.buffered\.length == 0\) \{\n            return;\n        \}\n\n        const drift = this\.sourceBuffer\.buffered\.end\(0\) - this\.\#attachedEl\.currentTime;\n        if \(drift > MediaSourcePlayer\.\#DRIFT_MAX_TOLERANCE\) \{\n            console\.log\(`\$\{drift\} drift exceeding tolerance, resyncing`\);\n            this\.\#attachedEl\.currentTime = this\.sourceBuffer\.buffered\.end\(0\);\n        \}\n    \}",
    replacement,
    text,
)
path.write_text(text)
PY

# noVNC 1.5+ and the audio plugin require a secure context (HTTPS). Match audio
# WebSocket encryption to the page protocol so WSS is used when served over TLS.
sed -i "s/NV.addInput(audioWsSettings, 'Encrypt', 'audio_encrypt', NVUI.getSetting('encrypt')/NV.addInput(audioWsSettings, 'Encrypt', 'audio_encrypt', (window.location.protocol === 'https:')/" "${NOVNC_DIR}/audio-plugin.js"
