#!/bin/sh
# Deploy both ultra players with matched configuration (serials differ per .env).
set -eu
export RA2_ULTRA_SERVICE="${RA2_ULTRA_SERVICE:-ra2-player-1 ra2-player-2}"
exec sh "$(CDPATH= cd -- "$(dirname "$0")" && pwd)/redeploy-ultra.sh"
