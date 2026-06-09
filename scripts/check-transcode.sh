#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

CONTAINER="${1:-ra2-player-1}"
RENDER_NODE="${RENDER_NODE:-/dev/dri/renderD128}"
COMPOSE_DIR="${COMPOSE_DIR:-/volume2/Data/App_Development/ra2-lan-party/project}"
ENV_FILE="${ENV_FILE:-$COMPOSE_DIR/.env}"
FAIL=0

if [ -f "$ENV_FILE" ]; then
  LIBVA_DRIVER_NAME="${LIBVA_DRIVER_NAME:-$(read_env_value LIBVA_DRIVER_NAME i965 "$ENV_FILE")}"
else
  LIBVA_DRIVER_NAME="${LIBVA_DRIVER_NAME:-i965}"
fi

print_manual_commands() {
  cat <<EOF

Run these directly on Synology if the helper script cannot reach Docker:

  sudo $DOCKER exec $CONTAINER sh -lc 'ls -la /dev/dri && id'
  sudo $DOCKER exec $CONTAINER sh -lc 'LIBVA_DRIVER_NAME=$LIBVA_DRIVER_NAME vainfo --display drm --device $RENDER_NODE'
  sudo $DOCKER exec $CONTAINER sh -lc '/usr/bin/ffmpeg -hide_banner -encoders | grep -i vaapi'
  sudo $DOCKER exec $CONTAINER sh -lc '/usr/bin/ffmpeg -hide_banner -encoders | grep -i qsv'
EOF
}

exec_in_container() {
  run_docker exec "$CONTAINER" sh -lc "$1"
}

check_pass() {
  printf '[OK] %s\n' "$1"
}

check_fail() {
  printf '[FAIL] %s\n' "$1"
  FAIL=1
}

printf 'Checking VA-API transcoding in %s\n' "$CONTAINER"
printf 'LIBVA_DRIVER_NAME=%s\n\n' "$LIBVA_DRIVER_NAME"

container_state="$(run_docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || true)"
if [ "$container_state" != "running" ]; then
  check_fail "container state is ${container_state:-unknown}"
  echo "Inspect startup logs first:"
  echo "  sudo $DOCKER logs --tail=100 $CONTAINER"
  print_manual_commands
  exit 1
fi

if ! exec_in_container "ls -la /dev/dri && id"; then
  check_fail "/dev/dri is not mounted in $CONTAINER"
  printf '\nRecreate players with the transcode overlay:\n'
  printf '  RA2_COMPOSE_TRANSCODE=1 sh scripts/bootstrap-nas.sh launch\n'
  printf '  or: docker compose --env-file .env -f compose.yaml -f compose.https.yaml -f compose.transcode.yaml up -d --force-recreate\n'
  print_manual_commands
  exit 1
fi

if exec_in_container "test ! -f /usr/lib/dri/iHD_drv_video.so"; then
  check_pass "iHD VA-API driver removed (Gemini Lake uses i965)"
else
  check_fail "iHD VA-API driver is still present"
fi

printf '\n== vainfo ==\n'
if exec_in_container "LIBVA_DRIVER_NAME='$LIBVA_DRIVER_NAME' vainfo --display drm --device '$RENDER_NODE'"; then
  if exec_in_container "LIBVA_DRIVER_NAME='$LIBVA_DRIVER_NAME' vainfo --display drm --device '$RENDER_NODE' 2>&1 | grep -Eq 'VAProfileH264|VAProfileHEVC'"; then
    check_pass "vainfo exposes H.264 or HEVC encode profiles"
  else
    check_fail "vainfo only exposes VAProfileNone (host i915 media engine not exposed)"
  fi
else
  check_fail "vainfo could not open $RENDER_NODE"
fi

printf '\n== ffmpeg vaapi encoders ==\n'
exec_in_container "/usr/bin/ffmpeg -hide_banner -encoders 2>/dev/null | grep -i vaapi || echo 'No VA-API encoders listed'"

printf '\n== ffmpeg qsv encoders ==\n'
exec_in_container "/usr/bin/ffmpeg -hide_banner -encoders 2>/dev/null | grep -i qsv || echo 'No QSV encoders listed'"

printf '\n== ffmpeg hwaccels ==\n'
exec_in_container "/usr/bin/ffmpeg -hide_banner -hwaccels 2>/dev/null || true"

VAAPI_OK=0

printf '\n== h264_vaapi smoke ==\n'
if exec_in_container "LIBVA_DRIVER_NAME='$LIBVA_DRIVER_NAME' ffmpeg -hide_banner -loglevel error -vaapi_device '$RENDER_NODE' -f lavfi -i testsrc2=size=128x128:rate=1 -vf format=nv12,hwupload -frames:v 1 -c:v h264_vaapi -f null -"; then
  check_pass "h264_vaapi encode smoke test passed"
  VAAPI_OK=1
else
  check_fail "h264_vaapi encode smoke test failed"
fi

printf '\n== hevc_vaapi smoke ==\n'
if exec_in_container "LIBVA_DRIVER_NAME='$LIBVA_DRIVER_NAME' ffmpeg -hide_banner -loglevel error -vaapi_device '$RENDER_NODE' -f lavfi -i testsrc2=size=128x128:rate=1 -vf format=nv12,hwupload -frames:v 1 -c:v hevc_vaapi -f null -"; then
  check_pass "hevc_vaapi encode smoke test passed"
  VAAPI_OK=1
else
  check_fail "hevc_vaapi encode smoke test failed"
fi

printf '\n== h264_qsv smoke ==\n'
if exec_in_container "ffmpeg -hide_banner -loglevel error -init_hw_device qsv=hw,child_device='$RENDER_NODE' -filter_hw_device hw -f lavfi -i testsrc2=size=128x128:rate=1 -frames:v 1 -c:v h264_qsv -f null -"; then
  check_pass "h264_qsv encode smoke test passed"
elif [ "$VAAPI_OK" -eq 1 ]; then
  printf '[WARN] h264_qsv encode smoke test failed (VA-API encode is available via i965)\n'
else
  check_fail "h264_qsv encode smoke test failed"
fi

printf '\nNotes for DS225+ / J4125:\n'
printf '  - render node access and FFmpeg encoder registration are required but not sufficient\n'
printf '  - if vainfo lacks H.264/HEVC profiles, Synology host i915 firmware (GuC/HuC) is the blocker\n'

if [ "$FAIL" -ne 0 ]; then
  print_manual_commands
  exit 1
fi

exit 0
