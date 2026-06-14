# Unpack/install StarCraft + Brood War from NAS ISOs.
#
# FullCD ISOs require Blizzard SETUP.EXE (GUI). Automated Wine/xdotool is unreliable;
# use launch-starcraft-setup.sh + browser stream, then finalize-starcraft-install.sh.
#
# Usage:
#   sh scripts/launch-starcraft-setup.sh          # start base install in player stream
#   sh scripts/finalize-starcraft-install.sh      # after Brood War SETUP completes
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
exec /bin/sh "$SCRIPT_DIR/launch-starcraft-setup.sh" "$@"
