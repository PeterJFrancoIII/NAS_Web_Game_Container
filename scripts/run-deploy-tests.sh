#!/bin/sh
# Pre-deploy test gate: WebRTC + full unit test suite (including AoE II session prep).
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

echo "[deploy-tests] WebRTC / ICE unit tests"
sh "$SCRIPT_DIR/run-webrtc-tests.sh"

echo "[deploy-tests] full unit test suite"
sh "$SCRIPT_DIR/run-tests.sh"

echo "[deploy-tests] ok"
