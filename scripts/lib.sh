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

tls_dir_from_env() {
  read_env_value TLS_DIR "/volume2/Data/App_Development/ra2-lan-party/tls" "${1:-.env}"
}

tls_cert_path() {
  printf '%s/cert.pem' "$(tls_dir_from_env "$1")"
}

tls_key_path() {
  printf '%s/key.pem' "$(tls_dir_from_env "$1")"
}

tls_material_present() {
  cert="$(tls_cert_path "$1")"
  key="$(tls_key_path "$1")"
  [ -f "$cert" ] && [ -f "$key" ]
}

file_owner_uid() {
  path="$1"
  if stat -c '%u' "$path" >/dev/null 2>&1; then
    stat -c '%u' "$path"
  else
    stat -f '%u' "$path"
  fi
}

tls_key_usable_by_container() {
  key="$(tls_key_path "$1")"
  cert="$(tls_cert_path "$1")"
  [ -f "$key" ] && [ -f "$cert" ] || return 1
  [ "$(file_owner_uid "$key")" = "1000" ] || return 1
  [ "$(file_owner_uid "$cert")" = "1000" ]
}

fix_tls_permissions() {
  env_file="${1:-.env}"
  if ! tls_material_present "$env_file"; then
    return 0
  fi

  cert="$(tls_cert_path "$env_file")"
  key="$(tls_key_path "$env_file")"
  chmod 644 "$cert" 2>/dev/null || true
  chmod 640 "$key" 2>/dev/null || true

  if [ "$(id -u)" -eq 0 ]; then
    chown 1000:1000 "$cert" "$key"
  elif command -v sudo >/dev/null 2>&1; then
    sudo chown 1000:1000 "$cert" "$key" 2>/dev/null || true
  fi
}

compose_file_args() {
  env_file="${1:-.env}"
  extra="${2:-}"

  printf '%s\n' "-f" "compose.yaml"
  if tls_material_present "$env_file"; then
    printf '%s\n' "-f" "compose.https.yaml"
  fi
  if [ "$extra" = "transcode" ]; then
    printf '%s\n' "-f" "compose.transcode.yaml"
  fi
  if [ "$extra" = "webrtc" ]; then
    printf '%s\n' "-f" "compose.webrtc.yaml"
  fi
}

transcode_overlay_enabled() {
  [ "${RA2_COMPOSE_TRANSCODE:-1}" != "0" ] && [ -f compose.transcode.yaml ]
}

webrtc_overlay_enabled() {
  [ "${RA2_COMPOSE_WEBRTC:-0}" = "1" ] && [ -f compose.webrtc.yaml ]
}

run_compose() {
  env_file="${1:-.env}"
  shift

  compose_args="-f compose.yaml"
  if tls_material_present "$env_file"; then
    compose_args="$compose_args -f compose.https.yaml"
  fi
  if transcode_overlay_enabled; then
    compose_args="$compose_args -f compose.transcode.yaml"
  fi
  if webrtc_overlay_enabled; then
    compose_args="$compose_args -f compose.webrtc.yaml"
  fi

  # shellcheck disable=SC2086
  run_docker compose --env-file "$env_file" $compose_args "$@"
}
