#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

X25_DIR="${X25_TRANSCODE_DIR:-/volume2/Data/App_Development/ra2-lan-party/x25-transcode}"
X25_RELEASE_URL="${X25_RELEASE_URL:-https://github.com/007revad/Transcode_for_x25/releases/download/v3.0.11/Transcode_v3.0.11_script.zip}"
X25_SCRIPT_URL="${X25_SCRIPT_URL:-https://raw.githubusercontent.com/007revad/Transcode_for_x25/v3.0.11/transcode_for_x25.sh}"
X25_SCRIPT="${X25_SCRIPT:-$X25_DIR/transcode_for_x25.sh}"

extract_zip() {
  archive="$1"
  dest="$2"

  if command -v unzip >/dev/null 2>&1; then
    unzip -o "$archive" -d "$dest"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$archive" "$dest" <<'PY'
import sys
import zipfile

zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
PY
    return 0
  fi

  if command -v python >/dev/null 2>&1; then
    python - "$archive" "$dest" <<'PY'
import sys
import zipfile

zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
PY
    return 0
  fi

  echo "Need unzip or python to extract $archive"
  return 1
}

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root on the Synology host:"
  echo "  sudo sh scripts/enable-host-transcode.sh"
  exit 1
fi

if ! uname -a | grep -q synology_geminilakenk; then
  echo "This helper targets Synology Gemini Lake models (DS225+/DS425+)."
  exit 1
fi

printf 'Synology ships a stripped i915 stack (enable_guc=0, no GuC/HuC firmware).\n'
printf 'This script loads the community x25 transcoding kernel modules.\n\n'

if sh "$SCRIPT_DIR/check-host-transcode.sh" >/dev/null 2>&1; then
  printf 'Host i915 media engine already looks ready.\n'
  if sh "$SCRIPT_DIR/check-transcode.sh" ra2-player-1; then
    exit 0
  fi
fi

mkdir -p "$X25_DIR"

printf 'Downloading Transcode_for_x25 v3.0.11 script...\n'
curl -fsSL -o "$X25_SCRIPT" "$X25_SCRIPT_URL"
chmod +x "$X25_SCRIPT"

printf 'Loading community i915 transcoding modules...\n'
export PATH="/usr/syno/bin:/usr/local/bin:/usr/sbin:/sbin:$PATH"
if ! command -v bash >/dev/null 2>&1; then
  echo "bash is required to run $X25_SCRIPT"
  exit 1
fi
printf 'n\n' | bash "$X25_SCRIPT"

sleep 2

printf '\n== host state ==\n'
if sh "$SCRIPT_DIR/check-host-transcode.sh"; then
  host_ok=1
else
  host_ok=0
fi

printf '\n== container probe ==\n'
if sh "$SCRIPT_DIR/check-transcode.sh" ra2-player-1; then
  printf '\nHardware transcoding is enabled.\n'
  printf 'Schedule %s at boot so the fix survives DSM updates/reboots.\n' "$X25_SCRIPT"
  exit 0
fi

if [ "$host_ok" -eq 0 ]; then
  printf '\nHost modules did not expose GuC/HuC. Schedule %s at boot or install the\n' "$X25_SCRIPT"
  printf 'Transcode_for_x25 package from Package Center.\n'
fi

exit 1
