#!/bin/sh
# WebRTC / ultra UDP unit tests — run before ultra deploys.
set -eu

cd "$(dirname "$0")/.."
PYTHON="${PYTHON:-python3}"
if ! command -v "$PYTHON" >/dev/null 2>&1; then
  PYTHON=python
fi

echo "[webrtc-tests] python: test_webrtc_ice test_gateway_webrtc_ice test_ultra_play_ice_utils test_remote_webrtc_contract test_turn_allocate_probe"
"$PYTHON" -m unittest \
  tests.test_webrtc_ice \
  tests.test_gateway_webrtc_ice \
  tests.test_ultra_play_ice_utils \
  tests.test_remote_webrtc_contract \
  tests.test_turn_allocate_probe \
  -v

if command -v node >/dev/null 2>&1; then
  echo "[webrtc-tests] node: ultra_play_ice_utils.test.mjs"
  node --test tests/ultra_play_ice_utils.test.mjs
else
  echo "[webrtc-tests] node not found — skipping browser ICE utils tests"
fi

echo "[webrtc-tests] ok"
