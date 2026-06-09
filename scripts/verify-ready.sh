#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR"

echo "== Local contract tests =="
sh "$SCRIPT_DIR/run-tests.sh"

echo
echo "== Shell syntax =="
for script in scripts/*.sh container/entrypoint.sh; do
  case "$script" in
    scripts/lib.sh) continue ;;
    container/entrypoint.sh) bash -n "$script" ;;
    *) sh -n "$script" ;;
  esac
  echo "[OK] $script"
done

if command -v docker >/dev/null 2>&1; then
  echo
  echo "== Docker Compose render =="
  docker compose --env-file .env.example -f compose.yaml config --quiet
  echo "[OK] compose.yaml renders"
  docker compose --env-file .env.example -f compose.yaml -f compose.https.yaml config --quiet
  echo "[OK] compose.yaml + compose.https.yaml render"
fi

echo
echo "Project verification complete."
