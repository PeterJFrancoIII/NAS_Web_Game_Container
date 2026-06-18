#!/bin/sh
# Post-deploy AoE II session prep smoke test inside a player container.
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

CONTAINER="${1:-${PLAYER1_CONTAINER:-Cloud_Gaming_Player1}}"

section() {
  printf '\n== %s ==\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

section "Container ${CONTAINER}"
status="$(container_status "$CONTAINER")"
if [ "$status" != "running" ]; then
  fail "${CONTAINER} is not running (status=${status:-missing})"
fi

section "AoE II script + config invariants"
run_docker exec "$CONTAINER" sh -lc '
  set -eu
  test -x /opt/ra2/prepare-aoe2-session.sh || { echo "missing prepare-aoe2-session.sh"; exit 1; }
  grep -q "InstalledGroup /t REG_SZ /d \"3\"" /opt/ra2/prepare-aoe2-session.sh || {
    echo "prepare script missing Conquerors InstalledGroup=3"
    exit 1
  }
  grep -q "register_wine_cdrom_drives" /opt/ra2/prepare-aoe2-session.sh || {
    echo "prepare script missing cdrom drive registration"
    exit 1
  }
  grep -q "AOE2_CD_PATH:-C:" /opt/ra2/prepare-aoe2-session.sh || {
    echo "prepare script CDPath must default to C:\\AOE2\\"
    exit 1
  }
  grep -q 'WINEPREFIX}/drive_c' /opt/ra2/prepare-aoe2-session.sh || {
    echo "prepare script must create WINEPREFIX/drive_c before AOE2 symlink"
    exit 1
  }
  if grep -q "wineLaunchCwdEnv" /opt/ra2/config/games.json; then
    echo "games.json must not set wineLaunchCwdEnv for aoe2"
    exit 1
  fi
  echo "script/config invariants ok"
'

section "AoE II assets mounted"
run_docker exec "$CONTAINER" sh -lc '
  set -eu
  test -f "${AOE2_ASSETS_DIR:-/home/commander/aoe2_assets}/EMPIRES2.EXE" || {
    echo "AoE II assets not mounted; skipping functional prep smoke"
    exit 0
  }
  test -d "${AOE2_STAGE:-/home/commander/aoe2_staging}/aok_cd" || {
    echo "AoE II disc staging missing; run scripts/stage-aoe2-discs.sh on NAS"
    exit 1
  }
  test -f "${AOE2_10C_DATA_DIR:-/home/commander/aoe2_10c_data}/empires2_x1_p1.dat" || {
    echo "AoE II 1.0c data missing; run scripts/stage-aoe2-10c-data.sh on NAS"
    exit 1
  }
  echo "assets/staging ok"
'

section "Functional prepare-aoe2-session smoke"
run_docker exec -u commander "$CONTAINER" sh -lc '
  set -eu
  ASSETS="${AOE2_ASSETS_DIR:-/home/commander/aoe2_assets}"
  if [ ! -f "$ASSETS/EMPIRES2.EXE" ]; then
    echo "skipped (no AoE II assets)"
    exit 0
  fi

  WORK="/tmp/aoe2-deploy-verify-$$"
  rm -rf "$WORK"
  mkdir -p "$WORK"

  /bin/sh /opt/ra2/prepare-aoe2-session.sh "$WORK" >/tmp/aoe2-deploy-verify.log 2>&1 || {
    tail -30 /tmp/aoe2-deploy-verify.log
    exit 1
  }

  wc -c "$WORK/EMPIRES2.EXE" "$WORK/age2_x1/age2_x1.exe" "$WORK/Data/empires2_x1_p1.dat" >/tmp/aoe2-deploy-verify.sizes
  awk "\$1 < 1000000 && \$2 ~ /age2_x1/ { bad=1 } END { exit bad }" /tmp/aoe2-deploy-verify.sizes || {
    echo "age2_x1.exe too small (retail/UserPatch stale exe?)"
    cat /tmp/aoe2-deploy-verify.sizes
    exit 1
  }

  cdpath_out="$(wine reg query "HKLM\\Software\\Microsoft\\Microsoft Games\\Age of Empires\\2.0" /v CDPath 2>/dev/null || true)"
  echo "$cdpath_out" | grep -q "CDPath" || {
    echo "base CDPath registry key missing"
    exit 1
  }
  echo "$cdpath_out" | grep -qi "aoe2" || {
    echo "base CDPath not under C:\\AOE2\\"
    printf '%s\n' "$cdpath_out"
    exit 1
  }
  wine reg query "HKLM\\Software\\Microsoft\\Microsoft Games\\Age of Empires II: The Conquerors Expansion\\1.0" /v InstalledGroup 2>/dev/null | grep -q "3" || {
    echo "Conquerors InstalledGroup not 3"
    exit 1
  }
  wine reg query "HKLM\\Software\\Wine\\Drives" 2>/dev/null | grep -q "cdrom" || {
    echo "Wine D:/E: not registered as cdrom"
    exit 1
  }

  rm -rf "$WORK"
  echo "functional prepare smoke ok"
'

printf '\nAoE II session verification complete.\n'
