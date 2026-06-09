# Shared helpers for RA2 NAS scripts. Source from /bin/sh scripts.

export PATH="/usr/local/bin:/usr/sbin:/sbin:$PATH"
DOCKER="${DOCKER:-/usr/local/bin/docker}"

run_docker() {
  if [ "$(id -u)" -eq 0 ]; then
    "$DOCKER" "$@"
    return $?
  fi

  if "$DOCKER" info >/dev/null 2>&1; then
    "$DOCKER" "$@"
    return $?
  fi

  if sudo -n "$DOCKER" info >/dev/null 2>&1; then
    sudo -n "$DOCKER" "$@"
    return $?
  fi

  echo "Docker is not accessible for this SSH user."
  echo "Re-run the script once with sudo, for example:"
  echo "  sudo sh scripts/$(basename "${0:-run-docker-script.sh}")"
  return 1
}

container_status() {
  run_docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || true
}

read_env_value() {
  key="$1"
  default="${2:-}"
  file="${3:-.env}"

  if [ ! -f "$file" ]; then
    printf '%s\n' "$default"
    return
  fi

  value="$(grep -E "^${key}=" "$file" | tail -n 1 | cut -d= -f2- | tr -d '\r')"
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$default"
  fi
}
