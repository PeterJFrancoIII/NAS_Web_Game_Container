#!/bin/sh
# Apply AoE II 1.0c patch data + UserPatch v1.5 (windowed off) on a writable tree.
set -eu

GAME_DIR="${1:?game dir required}"
AOE2_ASSETS_DIR="${AOE2_ASSETS_DIR:-/home/commander/aoe2_assets}"
PATCH_DATA_DIR="${AOE2_10C_DATA_DIR:-/home/commander/aoe2_10c_data}"
WINEPREFIX="${WINEPREFIX:-/home/commander/.wine}"
MARKER="${GAME_DIR}/.aoe2_userpatch_ready"
PATCH_MARKER="${GAME_DIR}/.aoe2_10c_patched"
SETUP_SRC="${AOE2_ASSETS_DIR}/SetupAoC.exe"

log() {
  printf '[aoe2-install] %s\n' "$*"
}

materialize_data_dir() {
  if [ -f "${GAME_DIR}/Data/empires2_x1_p1.dat" ]; then
    return 0
  fi
  if [ -L "${GAME_DIR}/Data" ]; then
    rm -f "${GAME_DIR}/Data"
  fi
  if [ ! -d "${GAME_DIR}/Data" ]; then
    cp -a "${AOE2_ASSETS_DIR}/Data" "${GAME_DIR}/Data"
    log "materialized writable Data/ (required for 1.0c patch files)"
  fi
}

materialize_age2_x1_dir() {
  src_dir="${AOE2_ASSETS_DIR}/age2_x1"
  dest_dir="${GAME_DIR}/age2_x1"
  if [ -L "$dest_dir" ]; then
    rm -f "$dest_dir"
  fi
  mkdir -p "$dest_dir"
  if [ -d "$src_dir" ]; then
    for path in "$src_dir"/* "$src_dir"/.[!.]* "$src_dir"/..?*; do
      [ -e "$path" ] || continue
      base="$(basename "$path")"
      case "$base" in
        AGE2_X1.EXE|age2_x1.exe|*.ICD|*.icd) continue ;;
      esac
      [ -e "$dest_dir/$base" ] || ln -sf "$path" "$dest_dir/$base" 2>/dev/null || true
    done
  fi
  installed=0
  for candidate in \
    "${GAME_DIR}/age2_x1/AGE2_X1.EXE" \
    "${AOE2_ASSETS_DIR}/age2_x1/AGE2_X1.EXE" \
    "${AOE2_ASSETS_DIR}/AGE2_X1.EXE" \
    "${AOE2_STAGE:-/home/commander/aoe2_staging}/aoc_cd/CRACK/AGE2_X1.EXE"; do
    if [ -f "$candidate" ]; then
      cp -f "$candidate" "${dest_dir}/age2_x1.exe"
      log "installed age2_x1.exe for UserPatch from ${candidate}"
      installed=1
      break
    fi
  done
  if [ "$installed" = "0" ] && [ -f "${PATCH_DATA_DIR}/age2_x1_10c.exe" ]; then
    cp -f "${PATCH_DATA_DIR}/age2_x1_10c.exe" "${dest_dir}/age2_x1.exe"
    log "warning: using retail 1.0c age2_x1.exe for UserPatch (no cracked binary found)"
  fi
  find "$dest_dir" -maxdepth 1 \( -iname '*.icd' -o -iname 'HA312W32.DLL' \) -exec rm -f {} + 2>/dev/null || true
}

apply_10c_patch_files() {
  if [ -f "$PATCH_MARKER" ] && [ -f "${GAME_DIR}/Data/empires2_x1_p1.dat" ]; then
    log "1.0c patch data already present"
    return 0
  fi
  materialize_data_dir
  for name in empires2_x1_p1.dat gamedata_x1_p1.drs; do
    src="${PATCH_DATA_DIR}/${name}"
    if [ ! -f "$src" ]; then
      log "error: missing ${src} (run scripts/stage-aoe2-10c-data.sh on the NAS host)"
      return 1
    fi
    cp -f "$src" "${GAME_DIR}/Data/${name}"
    log "installed Data/${name}"
  done
  if [ ! -f "${GAME_DIR}/Data/empires2_x1_p1.dat" ]; then
    log "error: empires2_x1_p1.dat still missing after staging"
    return 1
  fi
  touch "$PATCH_MARKER"
  log "Conquerors 1.0c data verified (empires2_x1_p1.dat)"
}

apply_userpatch() {
  if [ -f "$MARKER" ]; then
    if [ -f "${GAME_DIR}/age2_x1/age2_x1.exe" ] && [ ! -f "${GAME_DIR}/age2_x1/wndmode.dll" ]; then
      return 0
    fi
    rm -f "$MARKER"
  fi
  if [ ! -f "$SETUP_SRC" ]; then
    log "warning: SetupAoC.exe missing; cannot apply UserPatch"
    return 1
  fi
  materialize_age2_x1_dir
  rm -f "${GAME_DIR}/SetupAoC.exe" 2>/dev/null || true
  cp -f "$SETUP_SRC" "${GAME_DIR}/SetupAoC.exe"
  wine reg add "HKLM\\Software\\Microsoft\\Microsoft Games\\Age of Empires II: The Conquerors Expansion\\1.0" /v InstallationDirectory /t REG_SZ /d "C:\\AOE2\\" /f >/dev/null 2>&1 || true
  wine reg add "HKLM\\Software\\Microsoft\\Microsoft Games\\Age of Empires II: The Conquerors Expansion\\1.0" /v "EXE Path" /t REG_SZ /d "C:\\AOE2\\age2_x1\\" /f >/dev/null 2>&1 || true
  wine reg add "HKLM\\Software\\Microsoft\\Microsoft Games\\Age of Empires II\\1.0" /v InstallationDirectory /t REG_SZ /d "C:\\AOE2\\" /f >/dev/null 2>&1 || true
  log "applying UserPatch v1.5 (enhanced 1.0c, windowed mode disabled)"
  (
    cd "${GAME_DIR}"
    if command -v timeout >/dev/null 2>&1; then
      timeout 90 wine SetupAoC.exe -c -b -f:00000000000000 >>"${GAME_DIR}/patch-install.log" 2>&1
    else
      wine SetupAoC.exe -c -b -f:00000000000000 >>"${GAME_DIR}/patch-install.log" 2>&1
    fi
  ) || log "warning: UserPatch CLI returned non-zero or timed out"
  wineserver -k >/dev/null 2>&1 || true
  rm -f "${GAME_DIR}/age2_x1/wndmode.dll" "${GAME_DIR}/age2_x1/miniupnpc.dll" 2>/dev/null || true
  if [ ! -f "${GAME_DIR}/age2_x1/age2_x1.exe" ]; then
    log "error: UserPatch did not leave age2_x1/age2_x1.exe"
    tail -20 "${GAME_DIR}/patch-install.log" 2>/dev/null || true
    return 1
  fi
  exe_size="$(wc -c <"${GAME_DIR}/age2_x1/age2_x1.exe" | tr -d ' ')"
  if [ "$exe_size" -lt 2800000 ]; then
    log "warning: age2_x1.exe still looks unpatched (${exe_size} bytes)"
    tail -20 "${GAME_DIR}/patch-install.log" 2>/dev/null || true
    return 1
  fi
  touch "$MARKER"
  log "UserPatch applied to age2_x1/age2_x1.exe (${exe_size} bytes, no wndmode.dll)"
}

apply_10c_patch_files || exit 1
apply_userpatch || exit 1
