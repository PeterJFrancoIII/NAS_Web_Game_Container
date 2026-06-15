#!/bin/sh
# Backup the golden-master RA2 ultra stack on the NAS — excludes copyrighted game files.
# Creates: Docker image export + tar of project, prefixes, tls, logs, .env
#
# Usage (on NAS):
#   cd /volume2/Data/App_Development/ra2-lan-party/project
#   sh scripts/backup-golden-master.sh
#
# Usage (from Mac — runs backup on NAS via SSH):
#   NAS_HOST=MediaServer2 sh scripts/backup-golden-master.sh
set -eu

HOST="${NAS_HOST:-}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-/volume2/Data/App_Development/ra2-lan-party}"
BACKUP_ROOT="${BACKUP_ROOT:-${PROJECT_ROOT}/backups}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/golden-master-${STAMP}"
IMAGE_TAG="${RA2_ULTRA_IMAGE:-ra2-lan-party:ultra}"

run_on_nas() {
  if [ -n "$HOST" ]; then
    ssh "$HOST" "PROJECT_ROOT='$PROJECT_ROOT' BACKUP_ROOT='$BACKUP_ROOT' RA2_ULTRA_IMAGE='$IMAGE_TAG' sh -s" <<'EOF'
set -eu
. "${PROJECT_ROOT}/project/scripts/lib.sh" 2>/dev/null || true

BACKUP_DIR="${BACKUP_ROOT}/golden-master-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

echo "[backup] writing manifest"
cat >"$BACKUP_DIR/MANIFEST.txt" <<MANIFEST
RA2 NAS Golden Master backup
Tag: golden-master-2026-06-udp-lan
Created: $(date -Iseconds)
Host: $(hostname)
Image: ${RA2_ULTRA_IMAGE}
Excludes: assets/, assets-game1/, assets-game2/, RA2Yuri_Game1/
Includes: project/, prefixes/, tls/, logs/, .env (if present)
MANIFEST

echo "[backup] exporting Docker image ${RA2_ULTRA_IMAGE}"
if run_docker image inspect "${RA2_ULTRA_IMAGE}" >/dev/null 2>&1; then
  run_docker save "${RA2_ULTRA_IMAGE}" | gzip -1 >"$BACKUP_DIR/ra2-lan-party-ultra-image.tar.gz"
else
  echo "[backup] WARN: image ${RA2_ULTRA_IMAGE} not found — skipping image export"
fi

echo "[backup] archiving runtime tree (no game files)"
TAR_EXTRA=""
if command -v sudo >/dev/null 2>&1; then
  TAR_EXTRA="sudo"
fi
$TAR_EXTRA tar -czf "$BACKUP_DIR/ra2-golden-master-runtime.tar.gz" \
  -C "$PROJECT_ROOT" \
  --exclude='assets' \
  --exclude='assets-game1' \
  --exclude='assets-game2' \
  --exclude='RA2Yuri_Game1' \
  --exclude='backups' \
  project prefixes tls logs .env 2>/dev/null || \
$TAR_EXTRA tar -czf "$BACKUP_DIR/ra2-golden-master-runtime.tar.gz" \
  -C "$PROJECT_ROOT" \
  --exclude='assets' \
  --exclude='assets-game1' \
  --exclude='assets-game2' \
  --exclude='RA2Yuri_Game1' \
  --exclude='backups' \
  project prefixes tls logs

ls -lh "$BACKUP_DIR"
echo "[backup] complete: $BACKUP_DIR"
EOF
    return
  fi

  # Local / on-NAS direct execution
  BACKUP_DIR="${BACKUP_ROOT}/golden-master-${STAMP}"
  mkdir -p "$BACKUP_DIR"

  echo "[backup] writing manifest"
  cat >"$BACKUP_DIR/MANIFEST.txt" <<MANIFEST
RA2 NAS Golden Master backup
Tag: golden-master-2026-06-udp-lan
Created: $(date -Iseconds)
Host: $(hostname)
Image: ${IMAGE_TAG}
Excludes: assets/, assets-game1/, assets-game2/, RA2Yuri_Game1/
Includes: project/, prefixes/, tls/, logs/, .env (if present)
MANIFEST

  if [ -f "$SCRIPT_DIR/lib.sh" ]; then
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/lib.sh"
    DOCKER_CMD="run_docker"
  elif command -v docker >/dev/null 2>&1; then
    DOCKER_CMD="docker"
  else
    DOCKER_CMD=""
  fi

  if [ -n "$DOCKER_CMD" ] && $DOCKER_CMD image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    echo "[backup] exporting Docker image $IMAGE_TAG"
    $DOCKER_CMD save "$IMAGE_TAG" | gzip -1 >"$BACKUP_DIR/ra2-lan-party-ultra-image.tar.gz"
  else
    echo "[backup] WARN: image $IMAGE_TAG not found — skipping image export"
  fi

  echo "[backup] archiving runtime tree (no game files)"
  tar -czf "$BACKUP_DIR/ra2-golden-master-runtime.tar.gz" \
    -C "$PROJECT_ROOT" \
    --exclude='assets' \
    --exclude='assets-game1' \
    --exclude='assets-game2' \
    --exclude='RA2Yuri_Game1' \
    --exclude='backups' \
    project prefixes tls logs .env 2>/dev/null || \
  tar -czf "$BACKUP_DIR/ra2-golden-master-runtime.tar.gz" \
    -C "$PROJECT_ROOT" \
    --exclude='assets' \
    --exclude='assets-game1' \
    --exclude='assets-game2' \
    --exclude='RA2Yuri_Game1' \
    --exclude='backups' \
    project prefixes tls logs

  ls -lh "$BACKUP_DIR"
  echo "[backup] complete: $BACKUP_DIR"
}

run_on_nas
