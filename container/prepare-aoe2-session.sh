#!/bin/sh
# Prepare Wine + work dir for Age of Empires II (1999) browser sessions.
set -eu

GAME_DIR="${1:?game dir required}"
AOE2_ASSETS_DIR="${AOE2_ASSETS_DIR:-/home/commander/aoe2_assets}"
AOE2_PATCH_DIR="${AOE2_PATCH_DIR:-/home/commander/aoe2_patches}"
AOE2_STAGE="${AOE2_STAGE:-/home/commander/aoe2_staging}"
WINEPREFIX="${WINEPREFIX:-/home/commander/.wine}"
AOE2_LINK="${WINEPREFIX}/drive_c/AOE2"
DDRAW_DLL="${AOE2_DDRAW_DLL:-/home/commander/game_assets/ddraw.dll}"
DDRAW_INI="${AOE2_DDRAW_INI:-/opt/ra2/config/aoe2-ddraw.ini}"
USE_CNC_DDRAW="${AOE2_USE_CNC_DDRAW:-${useCncDdraw:-false}}"
ENABLE_USERPATCH="${AOE2_ENABLE_USERPATCH:-0}"
DESKTOP_W="${AOE2_VIRTUAL_DESKTOP_WIDTH:-${gameWidth:-800}}"
DESKTOP_H="${AOE2_VIRTUAL_DESKTOP_HEIGHT:-${gameHeight:-600}}"
VIRTUAL_DESKTOP="${DESKTOP_W}x${DESKTOP_H}"

log() {
  printf '[aoe2-session] %s\n' "$*"
}

materialize_file() {
  src="$1"
  dest="$2"
  name="$3"
  [ -f "$src" ] || return 1
  rm -f "$dest" 2>/dev/null || true
  if ! cp -f "$src" "$dest"; then
    log "error: failed to materialize ${name} to ${dest}"
    return 1
  fi
  log "materialized ${name}"
}

apply_language() {
  for name in LANGUAGE.DLL language.dll Language.dll; do
    if [ -f "${AOE2_ASSETS_DIR}/${name}" ]; then
      materialize_file "${AOE2_ASSETS_DIR}/${name}" "$GAME_DIR/LANGUAGE.DLL" "${name}"
      return 0
    fi
  done
  lang_dir="${AOE2_LANGUAGE_DIR:-/opt/ra2/config/aoe2-language}"
  for name in LANGUAGE.DLL language.dll Language.dll; do
    if [ -f "${lang_dir}/${name}" ]; then
      materialize_file "${lang_dir}/${name}" "$GAME_DIR/LANGUAGE.DLL" "${name}"
      return 0
    fi
  done
  log "warning: no LANGUAGE.DLL found for AoE II"
  return 1
}

strip_opengl_icds() {
  find "$GAME_DIR" -maxdepth 2 \( -iname '*.icd' -o -iname 'HA312W32.DLL' \) -exec rm -f {} + 2>/dev/null || true
}

purge_userpatch_artifacts() {
  rm -f \
    "${GAME_DIR}/.aoe2_userpatch_ready" \
    "${GAME_DIR}/.aoe2_10c_patched" \
    "${GAME_DIR}/SetupAoC.exe" \
    "${GAME_DIR}/patch-install.log" \
    "${GAME_DIR}/age2_x1/wndmode.dll" \
    "${GAME_DIR}/age2_x1/spectate.dll" \
    "${GAME_DIR}/age2_x1/spectate.exe" \
    "${GAME_DIR}/age2_x1/miniupnpc.dll" \
    2>/dev/null || true
}

install_ddraw_wrapper() {
  if [ "$USE_CNC_DDRAW" = "true" ] || [ "$USE_CNC_DDRAW" = "1" ]; then
    if [ -f "$DDRAW_DLL" ]; then
      cp -f "$DDRAW_DLL" "$GAME_DIR/ddraw.dll"
      log "installed cnc-ddraw from ${DDRAW_DLL}"
    else
      log "warning: cnc-ddraw missing at ${DDRAW_DLL}"
    fi
    if [ -f "$DDRAW_INI" ]; then
      cp -f "$DDRAW_INI" "$GAME_DIR/ddraw.ini"
      log "installed ddraw.ini from ${DDRAW_INI}"
    fi
    return 0
  fi

  rm -f "$GAME_DIR/ddraw.dll" "$GAME_DIR/ddraw.ini" 2>/dev/null || true
  log "using native Wine DirectDraw (cnc-ddraw disabled for AoE II)"
}

mount_wine_cd() {
  letter="$1"
  root="$2"
  dosdevices="${WINEPREFIX}/dosdevices"
  mkdir -p "$dosdevices"
  # Directory drives only (StarCraft pattern). d::/e:: ISO symlinks break Wine dir listing.
  rm -f "${dosdevices}/${letter}:" "${dosdevices}/${letter}::" 2>/dev/null || true
  if [ -n "$root" ] && [ -d "$root" ]; then
    root="$(CDPATH= cd -- "$root" && pwd)"
    ( CDPATH= cd -- /tmp && ln -sfn "$root" "${dosdevices}/${letter}:" )
    log "Wine ${letter}: -> ${root}"
  fi
}

install_cd_dlls() {
  system="${WINEPREFIX}/drive_c/windows/system"
  mkdir -p "$system" "$GAME_DIR"
  for disc in "${AOE2_STAGE}/aok_cd" "${AOE2_STAGE}/aoc_cd"; do
    [ -d "$disc" ] || continue
    for dll in CLCD16.DLL CLCD32.DLL; do
      if [ -f "${disc}/${dll}" ]; then
        cp -f "${disc}/${dll}" "${system}/${dll}"
        cp -f "${disc}/${dll}" "${GAME_DIR}/${dll}"
        log "installed ${dll} from ${disc}"
      fi
    done
    return 0
  done
  log "warning: CLCD DLLs missing (run scripts/stage-aoe2-discs.sh on the NAS)"
}

register_cd_paths() {
  # No-CD exes expect CDPath to point at the install tree, not D:/E: disc mounts.
  base_cd="${AOE2_CD_PATH:-C:\\\\AOE2\\\\}"
  aoc_cd="${AOE2_AOC_CD_PATH:-C:\\\\AOE2\\\\age2_x1\\\\}"
  aoc_install="${AOE2_AOC_INSTALL_PATH:-C:\\\\AOE2\\\\age2_x1\\\\}"

  wine reg add "HKLM\\Software\\Microsoft\\Microsoft Games\\Age of Empires\\2.0" /v CDPath /t REG_SZ /d "$base_cd" /f >/dev/null 2>&1 || true
  wine reg add "HKLM\\Software\\Microsoft\\Microsoft Games\\Age of Empires II\\1.0" /v CDPath /t REG_SZ /d "$base_cd" /f >/dev/null 2>&1 || true
  wine reg add "HKLM\\Software\\Microsoft\\Microsoft Games\\Age of Empires II\\1.0" /v CDPathAge2 /t REG_SZ /d "$aoc_cd" /f >/dev/null 2>&1 || true
  wine reg add "HKLM\\Software\\Microsoft\\Microsoft Games\\Age of Empires II: The Conquerors Expansion\\1.0" /v CDPath /t REG_SZ /d "$aoc_cd" /f >/dev/null 2>&1 || true
  wine reg add "HKLM\\Software\\Microsoft\\Microsoft Games\\Age of Empires II: The Conquerors Expansion\\1.0" /v CDPathAge2 /t REG_SZ /d "$aoc_cd" /f >/dev/null 2>&1 || true
  wine reg add "HKLM\\Software\\Microsoft\\Microsoft Games\\Age of Empires\\2.0" /v "EXE Path" /t REG_SZ /d "C:\\AOE2\\" /f >/dev/null 2>&1 || true
  wine reg add "HKLM\\Software\\Microsoft\\Microsoft Games\\Age of Empires\\2.0" /v InstallationDirectory /t REG_SZ /d "C:\\AOE2\\" /f >/dev/null 2>&1 || true
  wine reg add "HKLM\\Software\\Microsoft\\Microsoft Games\\Age of Empires\\2.0" /v InstalledGroup /t REG_SZ /d "1" /f >/dev/null 2>&1 || true
  wine reg add "HKLM\\Software\\Microsoft\\Microsoft Games\\Age of Empires\\2.0" /v InstallType /t REG_SZ /d "1" /f >/dev/null 2>&1 || true
  wine reg add "HKLM\\Software\\Microsoft\\Microsoft Games\\Age of Empires\\2.0" /v VersionType /t REG_SZ /d "RetailVersion" /f >/dev/null 2>&1 || true
  wine reg add "HKLM\\Software\\Microsoft\\Microsoft Games\\Age of Empires\\2.0" /v Version /t REG_SZ /d "2.0a" /f >/dev/null 2>&1 || true
  wine reg add "HKLM\\Software\\Microsoft\\Microsoft Games\\Age of Empires II\\1.0" /v InstallationDirectory /t REG_SZ /d "C:\\AOE2\\" /f >/dev/null 2>&1 || true
  wine reg add "HKLM\\Software\\Microsoft\\Microsoft Games\\Age of Empires II: The Conquerors Expansion\\1.0" /v InstallationDirectory /t REG_SZ /d "C:\\AOE2\\" /f >/dev/null 2>&1 || true
  wine reg add "HKLM\\Software\\Microsoft\\Microsoft Games\\Age of Empires II: The Conquerors Expansion\\1.0" /v "EXE Path" /t REG_SZ /d "$aoc_install" /f >/dev/null 2>&1 || true
  wine reg add "HKLM\\Software\\Microsoft\\Microsoft Games\\Age of Empires II: The Conquerors Expansion\\1.0" /v InstalledGroup /t REG_SZ /d "3" /f >/dev/null 2>&1 || true
  wine reg add "HKLM\\Software\\Microsoft\\Microsoft Games\\Age of Empires II: The Conquerors Expansion\\1.0" /v Version /t REG_SZ /d "1.0" /f >/dev/null 2>&1 || true
  wine reg add "HKLM\\Software\\Microsoft\\Microsoft Games\\Age of Empires II: The Conquerors Expansion\\1.0" /v VersionType /t REG_SZ /d "RetailVersion" /f >/dev/null 2>&1 || true
  wine reg add "HKLM\\Software\\Microsoft\\Microsoft Games\\Age of Empires II: The Conquerors Expansion\\1.0" /v Launched /t REG_SZ /d "1" /f >/dev/null 2>&1 || true
  wine reg add "HKLM\\Software\\Microsoft\\Microsoft Games\\Age of Empires II: The Conquerors Expansion\\1.0" /v LangID /t REG_DWORD /d 0x9 /f >/dev/null 2>&1 || true
  wine reg add "HKLM\\Software\\Microsoft\\Microsoft Games\\Age of Empires II: The Conquerors Expansion\\1.0" /v Zone /t REG_SZ /d "http://www.zone.com/conquerors" /f >/dev/null 2>&1 || true
  log "CDPath=${base_cd}; Conquerors CDPath/CDPathAge2=${aoc_cd}; Conquerors InstalledGroup=3"
}

register_wine_cdrom_drives() {
  wine reg add "HKLM\\Software\\Wine\\Drives" /v "d:" /t REG_SZ /d "cdrom" /f >/dev/null 2>&1 || true
  wine reg add "HKLM\\Software\\Wine\\Drives" /v "e:" /t REG_SZ /d "cdrom" /f >/dev/null 2>&1 || true
  log "Wine D: and E: registered as cdrom drives"
}

resolve_cracked_empires2() {
  for candidate in \
    "${AOE2_PATCH_DIR}/empires2.exe" \
    "${AOE2_STAGE}/aok_cd/cracked/empires2.exe" \
    "${AOE2_ASSETS_DIR}/EMPIRES2.EXE"; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

resolve_cracked_age2_x1() {
  for candidate in \
    "${AOE2_STAGE}/aoc_cd/CRACK/AGE2_X1.EXE" \
    "${AOE2_PATCH_DIR}/CRACK/AGE2_X1.EXE" \
    "${AOE2_ASSETS_DIR}/age2_x1/AGE2_X1.EXE"; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# AoE CD check reads GAME\*.EXE from D:/E: and compares with the installed binaries.
# Staged ISO trees ship retail exes (~280 KB); overlay cracked exes on a writable mirror.
build_cd_drive_root() {
  src_root="$1"
  dest_root="$2"
  cracked_rel="$3"
  cracked_src="$4"

  rm -rf "$dest_root"
  mkdir -p "$dest_root"

  for item in "$src_root"/*; do
    [ -e "$item" ] || continue
    base="$(basename "$item")"
    case "$base" in
      GAME) continue ;;
    esac
    ln -sfn "$item" "$dest_root/$base"
  done

  game_src="${src_root}/GAME"
  game_dest="${dest_root}/GAME"
  mkdir -p "$game_dest"

  case "$cracked_rel" in
    GAME/*/*)
      subdir="${cracked_rel#GAME/}"
      subdir="${subdir%/*}"
      cracked_name="$(basename "$cracked_rel")"
      for item in "$game_src"/*; do
        [ -e "$item" ] || continue
        base="$(basename "$item")"
        [ "$base" = "$subdir" ] && continue
        ln -sfn "$item" "$game_dest/$base"
      done
      sub_src="${game_src}/${subdir}"
      sub_dest="${game_dest}/${subdir}"
      mkdir -p "$sub_dest"
      for item in "$sub_src"/*; do
        [ -e "$item" ] || continue
        base="$(basename "$item")"
        [ "$base" = "$cracked_name" ] && continue
        case "$base" in
          *.ICD|*.icd) continue ;;
        esac
        ln -sfn "$item" "$sub_dest/$base"
      done
      cp -f "$cracked_src" "$sub_dest/$cracked_name"
      ;;
    GAME/*)
      cracked_name="${cracked_rel#GAME/}"
      for item in "$game_src"/*; do
        [ -e "$item" ] || continue
        base="$(basename "$item")"
        [ "$base" = "$cracked_name" ] && continue
        case "$base" in
          *.ICD|*.icd) continue ;;
        esac
        ln -sfn "$item" "$game_dest/$base"
      done
      cp -f "$cracked_src" "$game_dest/$cracked_name"
      ;;
    *)
      log "warning: unsupported CD overlay path ${cracked_rel}"
      return 1
      ;;
  esac
}

prepare_cd_mount_roots() {
  CD_CACHE="${GAME_DIR}/.cd-mounts"
  AOK_CD="${CD_CACHE}/aok"
  AOC_CD="${CD_CACHE}/aoc"
  aok_src="${AOE2_STAGE}/aok_cd"
  aoc_src="${AOE2_STAGE}/aoc_cd"
  empires2_crack="$(resolve_cracked_empires2 || true)"
  age2_x1_crack="$(resolve_cracked_age2_x1 || true)"

  mkdir -p "$CD_CACHE"
  if [ -d "$aok_src" ] && [ -n "$empires2_crack" ]; then
    build_cd_drive_root "$aok_src" "$AOK_CD" "GAME/EMPIRES2.EXE" "$empires2_crack"
    log "CD mirror D: with cracked GAME/EMPIRES2.EXE"
  else
    AOK_CD="$aok_src"
    log "warning: using read-only base CD tree for D:"
  fi

  if [ -d "$aoc_src" ] && [ -n "$age2_x1_crack" ]; then
    build_cd_drive_root "$aoc_src" "$AOC_CD" "GAME/AGE2_X1/AGE2_X1.EXE" "$age2_x1_crack"
    log "CD mirror E: with cracked GAME/AGE2_X1/AGE2_X1.EXE"
  else
    AOC_CD="$aoc_src"
    log "warning: using read-only Conquerors CD tree for E:"
  fi

  mount_wine_cd "d" "$AOK_CD"
  mount_wine_cd "e" "$AOC_CD"

  if [ ! -e "${WINEPREFIX}/dosdevices/d:" ]; then
    log "warning: base AoE II CD not mounted (run scripts/stage-aoe2-discs.sh on the NAS)"
  fi
}

mount_aoe2_cds() {
  prepare_cd_mount_roots
}

materialize_cracked_exe() {
  cracked="$(resolve_cracked_empires2 || true)"
  if [ -n "$cracked" ]; then
    materialize_file "$cracked" "$GAME_DIR/EMPIRES2.EXE" "$(basename "$cracked")"
    return 0
  fi
  log "warning: no EMPIRES2.EXE found to materialize"
  return 1
}

age2_x1_exe_size() {
  target="$1"
  if [ ! -f "$target" ]; then
    printf '0\n'
    return 0
  fi
  wc -c <"$target" | tr -d ' '
}

materialize_age2_x1_workdir() {
  cracked="$(resolve_cracked_age2_x1 || true)"
  [ -n "$cracked" ] || return 0

  dest_dir="${GAME_DIR}/age2_x1"
  src_dir="${AOE2_ASSETS_DIR}/age2_x1"
  stale=0

  if [ -L "$dest_dir" ]; then
    stale=1
  elif [ -f "${dest_dir}/age2_x1.exe" ]; then
    if [ "$(age2_x1_exe_size "${dest_dir}/age2_x1.exe")" -lt 1000000 ]; then
      stale=1
    fi
  elif [ -f "${dest_dir}/AGE2_X1.EXE" ]; then
    if [ "$(age2_x1_exe_size "${dest_dir}/AGE2_X1.EXE")" -lt 1000000 ]; then
      stale=1
    fi
  elif [ -e "$dest_dir" ] && [ ! -d "$dest_dir" ]; then
    stale=1
  fi

  if [ "$stale" = "1" ]; then
    rm -rf "$dest_dir"
    log "rebuilt stale age2_x1 work dir (retail/UserPatch exe or assets symlink)"
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

  materialize_file "$cracked" "${dest_dir}/AGE2_X1.EXE" "AGE2_X1.EXE" || return 1
  materialize_file "$cracked" "${dest_dir}/age2_x1.exe" "age2_x1.exe" || return 1
  find "$dest_dir" -maxdepth 1 \( -iname '*.icd' -o -iname 'HA312W32.DLL' \) -exec rm -f {} + 2>/dev/null || true
}

ensure_conquerors_data() {
  patch_data="${AOE2_10C_DATA_DIR:-/home/commander/aoe2_10c_data}"
  data_dir="${GAME_DIR}/Data"

  if [ -L "$data_dir" ]; then
    rm -f "$data_dir"
  fi
  if [ ! -d "$data_dir" ]; then
    cp -a "${AOE2_ASSETS_DIR}/Data" "$data_dir"
    log "materialized writable Data/ for Conquerors"
  fi

  for name in empires2_x1_p1.dat gamedata_x1_p1.drs; do
    src="${patch_data}/${name}"
    if [ ! -f "$src" ]; then
      log "warning: missing ${src} (run scripts/stage-aoe2-10c-data.sh on the NAS host)"
      return 1
    fi
    cp -f "$src" "${data_dir}/${name}"
  done
  log "Conquerors 1.0c data present in Data/"
}

mkdir -p "$GAME_DIR" "${WINEPREFIX}/drive_c"
rm -f "$AOE2_LINK" 2>/dev/null || true
ln -sf "$GAME_DIR" "$AOE2_LINK"

materialize_cracked_exe || true
apply_language || true
strip_opengl_icds
install_ddraw_wrapper
install_cd_dlls
mount_aoe2_cds

if [ "$ENABLE_USERPATCH" = "1" ] && [ -x /opt/ra2/install-aoe2-10c.sh ]; then
  if ! /bin/sh /opt/ra2/install-aoe2-10c.sh "$GAME_DIR"; then
    log "warning: AoE II UserPatch install incomplete; using cracked Conquerors exes"
    materialize_age2_x1_workdir || true
  fi
else
  purge_userpatch_artifacts
  ensure_conquerors_data || true
  materialize_age2_x1_workdir || true
fi

register_cd_paths
register_wine_cdrom_drives
SCREEN_SIZE_HEX="$(printf '%x' "$DESKTOP_W")"
wine reg add "HKCU\\Software\\Microsoft\\Microsoft Games\\Age of Empires\\2.0" /v "Screen Size" /t REG_DWORD /d "0x${SCREEN_SIZE_HEX}" /f >/dev/null 2>&1 || true
wine reg add "HKCU\\Software\\Microsoft\\Microsoft Games\\Age of Empires\\2.0" /v "Graphics Detail Level" /t REG_DWORD /d 0x0 /f >/dev/null 2>&1 || true
wine reg add "HKCU\\Software\\Wine\\Direct3D" /v renderer /t REG_SZ /d gdi /f >/dev/null 2>&1 || true
wine reg add "HKCU\\Software\\Wine\\Explorer\\Desktops" /v Default /t REG_SZ /d "$VIRTUAL_DESKTOP" /f >/dev/null 2>&1 || true
wine reg add "HKCU\\Software\\Wine\\AppDefaults\\EMPIRES2.EXE\\Version" /v Version /t REG_SZ /d win2k /f >/dev/null 2>&1 || true
wine reg add "HKCU\\Software\\Wine\\AppDefaults\\AGE2_X1.EXE\\Version" /v Version /t REG_SZ /d win2k /f >/dev/null 2>&1 || true
wineserver -k >/dev/null 2>&1 || true

log "AoE II session ready at C:\\AOE2\\ (${VIRTUAL_DESKTOP}; launch cwd=${GAME_DIR})"
