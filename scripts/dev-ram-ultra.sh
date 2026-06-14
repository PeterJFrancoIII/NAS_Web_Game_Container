#!/bin/sh
# RAM-backed ultra debug player — run ON the Synology NAS.
#
# /dev/shm/ra2-dev/ holds: project mirror (all bind mounts), Wine prefix, assets, TLS.
# Container tmpfs holds: logs, state, cache, /tmp, stream-helper binary.
#
# On the NAS (recommended):
#   cd /volume2/Data/App_Development/ra2-lan-party/project
#   sudo sh scripts/nas-ram.sh up
#   sudo vi /dev/shm/ra2-dev/project/container/remote-ultra/ultra-play.js
#   sudo sh scripts/nas-ram.sh gw
#
# From a Mac (optional — seeds disk then runs nas-ram on the NAS):
#   NAS_HOST=MediaServer2Local sh scripts/sync-to-ram.sh
#
# Actions: up | refresh | gw | game | audio | recreate | status | reset-mirror
# Force lightweight mode on small hosts: DEV_RAM_FULL=0 sh scripts/nas-ram.sh up
set -eu

ACTION="${1:-up}"
SERVICE="${RA2_RAM_SERVICE:-ra2-player-dev}"
HTTP_PORT="${DEV_RAM_HTTP_PORT:-6091}"
NAS_LAN_IP="${NAS_LAN_IP:-192.168.0.193}"
CONTAINER_UID="${CONTAINER_UID:-1000}"
CONTAINER_GID="${CONTAINER_GID:-1000}"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
DISK_PROJECT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
COMPOSE_ROOT="$DISK_PROJECT"

if [ -n "${NAS_HOST:-}" ] && [ -z "${RA2_RAM_LOCAL:-}" ]; then
  TARGET="${NAS_TARGET:-/volume2/Data/App_Development/ra2-lan-party/project}"
  echo "[dev-ram] syncing to ${NAS_HOST}:${TARGET}"
  NAS_HOST="$NAS_HOST" NAS_TARGET="$TARGET" sh "$SCRIPT_DIR/sync-to-nas.sh"
  ssh "$NAS_HOST" "cd '$TARGET' && sudo -n sh -c 'RA2_RAM_LOCAL=1 sh scripts/dev-ram-ultra.sh $ACTION'"
  exit $?
fi

. "$SCRIPT_DIR/lib.sh"

host_ram_mib() {
  if [ -r /proc/meminfo ]; then
    awk '/MemTotal:/ {printf "%d\n", int($2 / 1024 + 0.5)}' /proc/meminfo
    return 0
  fi
  if command -v sysctl >/dev/null 2>&1; then
    bytes="$(sysctl -n hw.memsize 2>/dev/null || true)"
    if [ -n "$bytes" ]; then
      printf '%d\n' $((bytes / 1024 / 1024))
      return 0
    fi
  fi
  printf '0\n'
}

apply_ram_defaults() {
  mib="$(host_ram_mib)"
  if [ "${DEV_RAM_FULL:-}" = "0" ]; then
    export DEV_RAM_MEM_LIMIT="${DEV_RAM_MEM_LIMIT:-768m}"
    export DEV_RAM_SHM_SIZE="${DEV_RAM_SHM_SIZE:-512m}"
    export DEV_RAM_TMPFS_LOGS="${DEV_RAM_TMPFS_LOGS:-384m}"
    export DEV_RAM_TMPFS_STATE="${DEV_RAM_TMPFS_STATE:-32m}"
    export DEV_RAM_TMPFS_CACHE="${DEV_RAM_TMPFS_CACHE:-64m}"
    export DEV_RAM_TMPFS_TMP="${DEV_RAM_TMPFS_TMP:-512m}"
    export DEV_RAM_TMPFS_OPT="${DEV_RAM_TMPFS_OPT:-32m}"
    echo "[dev-ram] lightweight profile (host ${mib} MiB, DEV_RAM_FULL=0)"
    return 0
  fi

  if [ -n "${DEV_RAM_MEM_LIMIT:-}" ]; then
    return 0
  fi

  if [ "$mib" -ge 12288 ]; then
    export DEV_RAM_FULL="${DEV_RAM_FULL:-1}"
    export DEV_RAM_MEM_LIMIT="${DEV_RAM_MEM_LIMIT:-5120m}"
    export DEV_RAM_SHM_SIZE="${DEV_RAM_SHM_SIZE:-2048m}"
    export DEV_RAM_TMPFS_LOGS="${DEV_RAM_TMPFS_LOGS:-1536m}"
    export DEV_RAM_TMPFS_STATE="${DEV_RAM_TMPFS_STATE:-64m}"
    export DEV_RAM_TMPFS_CACHE="${DEV_RAM_TMPFS_CACHE:-256m}"
    export DEV_RAM_TMPFS_TMP="${DEV_RAM_TMPFS_TMP:-2048m}"
    export DEV_RAM_TMPFS_OPT="${DEV_RAM_TMPFS_OPT:-128m}"
    echo "[dev-ram] full-RAM profile (host ${mib} MiB)"
    return 0
  fi

  if [ "$mib" -ge 6144 ]; then
    export DEV_RAM_MEM_LIMIT="${DEV_RAM_MEM_LIMIT:-2048m}"
    export DEV_RAM_SHM_SIZE="${DEV_RAM_SHM_SIZE:-1024m}"
    export DEV_RAM_TMPFS_LOGS="${DEV_RAM_TMPFS_LOGS:-512m}"
    export DEV_RAM_TMPFS_STATE="${DEV_RAM_TMPFS_STATE:-48m}"
    export DEV_RAM_TMPFS_CACHE="${DEV_RAM_TMPFS_CACHE:-128m}"
    export DEV_RAM_TMPFS_TMP="${DEV_RAM_TMPFS_TMP:-768m}"
    export DEV_RAM_TMPFS_OPT="${DEV_RAM_TMPFS_OPT:-64m}"
    echo "[dev-ram] medium-RAM profile (host ${mib} MiB)"
    return 0
  fi

  export DEV_RAM_MEM_LIMIT="${DEV_RAM_MEM_LIMIT:-768m}"
  export DEV_RAM_SHM_SIZE="${DEV_RAM_SHM_SIZE:-512m}"
  export DEV_RAM_TMPFS_LOGS="${DEV_RAM_TMPFS_LOGS:-384m}"
  export DEV_RAM_TMPFS_STATE="${DEV_RAM_TMPFS_STATE:-32m}"
  export DEV_RAM_TMPFS_CACHE="${DEV_RAM_TMPFS_CACHE:-64m}"
  export DEV_RAM_TMPFS_TMP="${DEV_RAM_TMPFS_TMP:-512m}"
  export DEV_RAM_TMPFS_OPT="${DEV_RAM_TMPFS_OPT:-32m}"
  echo "[dev-ram] lightweight profile (host ${mib} MiB)"
}

ram_root() {
  if [ -n "${RAM_ROOT:-}" ]; then
    printf '%s\n' "$RAM_ROOT"
    return
  fi
  if [ -d /dev/shm ] && [ -w /dev/shm ]; then
    printf '%s\n' "/dev/shm/ra2-dev"
    return
  fi
  printf '%s\n' "/tmp/ra2-dev"
}

ram_chown_tree() {
  target="$1"
  if chown -R "$CONTAINER_UID:$CONTAINER_GID" "$target" 2>/dev/null; then
    chmod -R u+rwX "$target" 2>/dev/null || true
    return 0
  fi
  if sudo -n chown -R "$CONTAINER_UID:$CONTAINER_GID" "$target" 2>/dev/null; then
    sudo -n chmod -R u+rwX "$target"
    return 0
  fi
  if sudo chown -R "$CONTAINER_UID:$CONTAINER_GID" "$target"; then
    sudo chmod -R u+rwX "$target"
    return 0
  fi
  echo "[dev-ram] failed to chown $target to ${CONTAINER_UID}:${CONTAINER_GID}" >&2
  return 1
}

ram_rsync() {
  src="$1"
  dst="$2"
  shift 2
  mkdir -p "$dst"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "$@" "$src" "$dst"
    return $?
  fi
  rm -rf "$dst"/*
  cp -a "$src/." "$dst/"
}

apply_ram_defaults
RAM_ROOT="$(ram_root)"
RAM_PROJECT="${RAM_PROJECT_DIR:-$RAM_ROOT/project}"
RAM_PREFIX="${RAM_PREFIX_DIR:-$RAM_ROOT/prefix-player1}"
RAM_ASSETS="${RAM_ASSETS_DIR:-$RAM_ROOT/assets}"
RAM_TLS="${RAM_TLS_DIR:-$RAM_ROOT/tls}"
ENV_FILE="${DISK_PROJECT}/.env"
SOURCE_PREFIX="${PREFIX1_DIR:-$(read_env_value PREFIX1_DIR "$DISK_PROJECT/../prefixes/player1-win32" "$ENV_FILE")}"
SOURCE_ASSETS="${ASSETS_DIR:-$(read_env_value ASSETS_DIR "$DISK_PROJECT/../assets" "$ENV_FILE")}"
SOURCE_TLS="$(tls_dir_from_env "$ENV_FILE")"
ASSETS_MARKER="${RAM_ASSETS}/.ra2_assets_seeded"
PROJECT_MARKER="${RAM_PROJECT}/.ra2_mirror_ready"
TLS_MARKER="${RAM_TLS}/.ra2_tls_seeded"

seed_project_mirror() {
  if [ "${DEV_RAM_FULL:-0}" != "1" ]; then
    COMPOSE_ROOT="$DISK_PROJECT"
    echo "[dev-ram] compose from disk: $COMPOSE_ROOT"
    return 0
  fi

  force="${DEV_RAM_REFRESH_MIRROR:-0}"
  if [ "$force" != "1" ] && [ -f "$PROJECT_MARKER" ]; then
    echo "[dev-ram] RAM project mirror ready at $RAM_PROJECT"
  else
    echo "[dev-ram] mirroring project $DISK_PROJECT -> $RAM_PROJECT"
    ram_rsync "$DISK_PROJECT/" "$RAM_PROJECT/" --delete \
      --exclude '.git/' \
      --exclude '__pycache__/' \
      --exclude '.DS_Store' \
      --exclude '._*' \
      --exclude '.env'
    if [ -f "$ENV_FILE" ]; then
      cp -f "$ENV_FILE" "$RAM_PROJECT/.env"
    fi
    touch "$PROJECT_MARKER"
  fi
  COMPOSE_ROOT="$RAM_PROJECT"
  export RAM_PROJECT_DIR="$RAM_PROJECT"
}

seed_tls() {
  if [ "${DEV_RAM_FULL:-0}" != "1" ]; then
    return 0
  fi
  if [ ! -d "$SOURCE_TLS" ]; then
    echo "[dev-ram] TLS source missing: $SOURCE_TLS (skipping RAM TLS copy)" >&2
    return 0
  fi
  force="${DEV_RAM_REFRESH_MIRROR:-0}"
  if [ "$force" = "1" ] || [ ! -f "$TLS_MARKER" ]; then
    echo "[dev-ram] mirroring TLS $SOURCE_TLS -> $RAM_TLS"
    ram_rsync "$SOURCE_TLS/" "$RAM_TLS/" --delete
    touch "$TLS_MARKER"
  else
    echo "[dev-ram] RAM TLS ready at $RAM_TLS"
  fi
  export RAM_TLS_DIR="$RAM_TLS"
}

seed_prefix() {
  mkdir -p "$RAM_PREFIX"
  if [ -f "$RAM_PREFIX/.ra2_initialized" ]; then
    echo "[dev-ram] RAM prefix ready at $RAM_PREFIX"
    return 0
  fi
  if [ ! -d "$SOURCE_PREFIX" ]; then
    echo "[dev-ram] source prefix missing: $SOURCE_PREFIX" >&2
    echo "[dev-ram] run prepare-nas / initialize player1 prefix first" >&2
    return 1
  fi
  echo "[dev-ram] seeding RAM prefix from $SOURCE_PREFIX -> $RAM_PREFIX"
  ram_rsync "$SOURCE_PREFIX/" "$RAM_PREFIX/" --delete
  ram_chown_tree "$RAM_PREFIX"
}

seed_assets() {
  if [ "${DEV_RAM_FULL:-0}" != "1" ]; then
    echo "[dev-ram] game assets from disk: $SOURCE_ASSETS"
    return 0
  fi
  mkdir -p "$RAM_ASSETS"
  force="${DEV_RAM_REFRESH_MIRROR:-0}"
  if [ "$force" != "1" ] && [ -f "$ASSETS_MARKER" ]; then
    echo "[dev-ram] RAM assets ready at $RAM_ASSETS"
    export RAM_ASSETS_DIR="$RAM_ASSETS"
    return 0
  fi
  if [ ! -d "$SOURCE_ASSETS" ]; then
    echo "[dev-ram] source assets missing: $SOURCE_ASSETS" >&2
    return 1
  fi
  echo "[dev-ram] seeding RAM assets from $SOURCE_ASSETS -> $RAM_ASSETS"
  ram_rsync "$SOURCE_ASSETS/" "$RAM_ASSETS/"
  touch "$ASSETS_MARKER"
  ram_chown_tree "$RAM_ASSETS"
  export RAM_ASSETS_DIR="$RAM_ASSETS"
}

prepare_ram_stack() {
  seed_project_mirror
  seed_tls
  seed_prefix
  seed_assets
  export RAM_PREFIX_DIR="$RAM_PREFIX"
  if [ "${DEV_RAM_FULL:-0}" = "1" ]; then
    export RAM_ASSETS_DIR="$RAM_ASSETS"
    [ -d "$RAM_TLS" ] && export RAM_TLS_DIR="$RAM_TLS"
  fi
}

compose_ram() {
  prepare_ram_stack
  export RA2_COMPOSE_ULTRA=1
  (
    cd "$COMPOSE_ROOT"
    run_compose "$COMPOSE_ROOT/.env" --profile ram-dev "$@"
  )
}

print_ram_status() {
  echo "[dev-ram] host RAM: $(host_ram_mib) MiB"
  echo "[dev-ram] profile: mem=${DEV_RAM_MEM_LIMIT:-?} shm=${DEV_RAM_SHM_SIZE:-?}"
  echo "[dev-ram] compose root: $COMPOSE_ROOT"
  if [ "${DEV_RAM_FULL:-0}" = "1" ] && [ -d "$RAM_PROJECT" ]; then
    echo "[dev-ram] project mirror: $RAM_PROJECT"
    du -sh "$RAM_PROJECT" 2>/dev/null || true
  fi
  echo "[dev-ram] prefix: $RAM_PREFIX"
  if [ -d "$RAM_PREFIX" ]; then
    du -sh "$RAM_PREFIX" 2>/dev/null || true
  fi
  if [ "${DEV_RAM_FULL:-0}" = "1" ] && [ -d "$RAM_ASSETS" ]; then
    echo "[dev-ram] assets: $RAM_ASSETS"
    du -sh "$RAM_ASSETS" 2>/dev/null || true
  else
    echo "[dev-ram] assets: $SOURCE_ASSETS (disk)"
  fi
  if [ "${DEV_RAM_FULL:-0}" = "1" ] && [ -d "$RAM_TLS" ]; then
    echo "[dev-ram] tls: $RAM_TLS"
    du -sh "$RAM_TLS" 2>/dev/null || true
  fi
  if [ -d /dev/shm ]; then
    echo "[dev-ram] /dev/shm:"
    df -h /dev/shm 2>/dev/null || true
    du -sh "$RAM_ROOT" 2>/dev/null || true
  fi
}

case "$ACTION" in
  up)
    compose_ram up -d --no-build --force-recreate "$SERVICE"
    print_ram_status
    echo "[dev-ram] URL: https://${NAS_LAN_IP}:${HTTP_PORT}/"
    echo "[dev-ram] edit in RAM: ${RAM_PROJECT}/container/remote-ultra/"
    echo "[dev-ram] then: sudo sh scripts/nas-ram.sh gw"
    ;;
  recreate)
    compose_ram up -d --no-build --force-recreate "$SERVICE"
    print_ram_status
    ;;
  refresh)
    export DEV_RAM_REFRESH_MIRROR=1
    compose_ram up -d --no-build "$SERVICE"
    sleep 3
    run_docker exec "$SERVICE" sh -lc '
      set -eu
      FPS="${ULTRA_VIDEO_FPS:-24}"
      W="${ULTRA_VIDEO_WIDTH:-1024}"
      H="${ULTRA_VIDEO_HEIGHT:-768}"
      if [ -f /home/commander/.ra2/display.env ]; then
        . /home/commander/.ra2/display.env
        W="${RA2_DISPLAY_WIDTH:-$W}"
        H="${RA2_DISPLAY_HEIGHT:-$H}"
      fi
      /bin/sh /opt/ra2/sync-game-transport.sh "$FPS" "$W" "$H"
      supervisorctl -c /opt/ra2/supervisord.conf restart stream-gateway game
    '
    print_ram_status
    echo "[dev-ram] RAM mirror refreshed; stream-gateway + game restarted from RAM binds"
    ;;
  down)
    compose_ram down "$SERVICE"
    ;;
  gw|gateway)
    run_docker exec "$SERVICE" supervisorctl -c /opt/ra2/supervisord.conf restart stream-gateway
    echo "[dev-ram] stream-gateway restarted (bind mounts served from RAM)"
    ;;
  game)
    run_docker exec "$SERVICE" sh -lc '
      set -eu
      FPS="${ULTRA_VIDEO_FPS:-24}"
      W="${ULTRA_VIDEO_WIDTH:-1024}"
      H="${ULTRA_VIDEO_HEIGHT:-768}"
      if [ -f /home/commander/.ra2/display.env ]; then
        . /home/commander/.ra2/display.env
        W="${RA2_DISPLAY_WIDTH:-$W}"
        H="${RA2_DISPLAY_HEIGHT:-$H}"
      fi
      /bin/sh /opt/ra2/sync-game-transport.sh "$FPS" "$W" "$H"
      supervisorctl -c /opt/ra2/supervisord.conf restart game
    '
    echo "[dev-ram] game restarted (ddraw.ini synced from RAM binds)"
    ;;
  audio)
    run_docker exec "$SERVICE" sh -lc '
      set -eu
      RATE="${ULTRA_AUDIO_RATE:-48000}"
      ENC="${ULTRA_AUDIO_CODEC:-opus}"
      /bin/sh /opt/ra2/sync-audio-transport.sh "$RATE" "$RATE" "$ENC"
      supervisorctl -c /opt/ra2/supervisord.conf restart pulseaudio stream-gateway
    '
    echo "[dev-ram] pulseaudio + stream-gateway restarted (audio=${ULTRA_AUDIO_RATE:-48000}Hz)"
    ;;
  display)
    RES="${2:-1024x768}"
    run_docker exec "$SERVICE" /bin/sh /opt/ra2/apply-ultra-display.sh "$RES"
    ;;
  shell)
    run_docker exec -it "$SERVICE" bash
    ;;
  logs)
    run_docker logs -f --tail 100 "$SERVICE"
    ;;
  status)
    prepare_ram_stack
    print_ram_status
    run_docker exec "$SERVICE" sh -lc '
      set -eu
      cat /home/commander/.ra2/display.env 2>/dev/null || true
      DISPLAY=:1 xdpyinfo 2>/dev/null | grep dimensions || true
      supervisorctl -c /opt/ra2/supervisord.conf status || true
      pgrep -af gamemd || true
      pgrep -af stream-helper || true
      echo "--- container tmpfs ---"
      df -h /home/commander/ra2-logs-root /home/commander/.ra2 /home/commander/.cache /tmp 2>/dev/null || true
      tail -10 /home/commander/ra2-logs-root/player1/gateway.log 2>/dev/null || true
    '
    ;;
  reset-prefix)
    rm -rf "$RAM_PREFIX"
    seed_prefix
    ;;
  reset-assets)
    rm -rf "$RAM_ASSETS"
    DEV_RAM_REFRESH_MIRROR=1 seed_assets
    ;;
  reset-mirror)
    rm -rf "$RAM_PROJECT" "$RAM_TLS"
    DEV_RAM_REFRESH_MIRROR=1 prepare_ram_stack
    print_ram_status
    ;;
  *)
    echo "usage: $0 {up|recreate|refresh|down|gw|game|audio|display|shell|logs|status|reset-prefix|reset-assets|reset-mirror}" >&2
    exit 1
    ;;
esac
