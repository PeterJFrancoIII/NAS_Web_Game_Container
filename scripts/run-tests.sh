#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
PYTHON="${PYTHON:-python3}"
if ! command -v "$PYTHON" >/dev/null 2>&1; then
  PYTHON=python
fi
"$PYTHON" -m unittest discover -s tests -v
