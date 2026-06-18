#!/bin/sh
# Prepare Wine for StarCraft + Brood War: no-CD mpq files and CD drive mounts.
set -eu

GAME_DIR="${1:?game dir required}"
SC_DISC_DIR="${SC_DISC_DIR:-/home/commander/sc_disc}"
SC_STAGE="${SC_STAGE:-/home/commander/sc_staging}"
WINEPREFIX="${WINEPREFIX:-/home/commander/.wine}"
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree=d;mshtml=d;comctl32=b}"

log() {
  printf '[sc-session] %s\n' "$*"
}

ensure_mpq() {
  src="$1"
  dest="$2"
  name="$3"
  if [ -f "$dest" ] && [ ! -L "$dest" ]; then
    return 0
  fi
  rm -f "$dest" 2>/dev/null || true
  if [ -f "$src" ]; then
    cp -f "$src" "$dest"
    log "installed ${name} from ${src}"
    return 0
  fi
  log "warning: ${name} missing at ${dest}"
  return 1
}

materialize_file() {
  src="$1"
  dest="$2"
  name="$3"
  [ -f "$src" ] || return 1
  rm -f "$dest" 2>/dev/null || true
  cp -f "$src" "$dest"
  log "materialized ${name} in work dir"
}

resolve_disc_root() {
  kind="$1"
  case "$kind" in
    sc_cd) tmp="/tmp/sc_install_sc" ;;
    bw_cd) tmp="/tmp/sc_install_bw" ;;
    *) tmp="" ;;
  esac
  for candidate in \
    "${SC_STAGE}/${kind}" \
    "${SC_DISC_DIR}/${kind}" \
    "$tmp"; do
    if [ -f "${candidate}/SETUP.EXE" ] || [ -f "${candidate}/INSTALL.EXE" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

mount_wine_cds() {
  sc_root="$(resolve_disc_root sc_cd || true)"
  bw_root="$(resolve_disc_root bw_cd || true)"
  dosdevices="${WINEPREFIX}/dosdevices"
  mkdir -p "$dosdevices"

  if [ -n "$sc_root" ]; then
    sc_root="$(CDPATH= cd -- "$sc_root" && pwd)"
    rm -f "${dosdevices}/d:" 2>/dev/null || true
    ( CDPATH= cd -- /tmp && ln -sfn "$sc_root" "${dosdevices}/d:" )
    log "Wine D: -> ${sc_root}"
  else
    log "warning: base StarCraft disc files missing (expected ${SC_STAGE}/sc_cd)"
  fi
  if [ -n "$bw_root" ]; then
    bw_root="$(CDPATH= cd -- "$bw_root" && pwd)"
    rm -f "${dosdevices}/e:" 2>/dev/null || true
    ( CDPATH= cd -- /tmp && ln -sfn "$bw_root" "${dosdevices}/e:" )
    log "Wine E: -> ${bw_root}"
  else
    log "warning: Brood War disc files missing (expected ${SC_STAGE}/bw_cd)"
  fi
}

update_registry() {
  sc_link="${WINEPREFIX}/drive_c/SC"
  rm -f "$sc_link" 2>/dev/null || true
  ln -sf "$GAME_DIR" "$sc_link"
  wine reg add "HKLM\\Software\\Blizzard Entertainment\\Starcraft" /v InstallPath /t REG_SZ /d "C:\\SC\\" /f >/dev/null 2>&1 || true
  wine reg add "HKLM\\Software\\Blizzard Entertainment\\Starcraft" /v StarCD /t REG_SZ /d "C:\\SC\\" /f >/dev/null 2>&1 || true
  wine reg add "HKLM\\Software\\Blizzard Entertainment\\Starcraft" /v Brood War /t REG_SZ /d y /f >/dev/null 2>&1 || true
  wine reg add "HKLM\\Software\\Blizzard Entertainment\\Starcraft" /v Program /t REG_SZ /d "C:\\SC\\StarCraft.exe" /f >/dev/null 2>&1 || true
  wineserver -k >/dev/null 2>&1 || true
  log "SC -> ${GAME_DIR}; InstallPath=C:\\SC\\ StarCD=C:\\SC\\"
}

install_cd_vxds() {
  iosub="${WINEPREFIX}/drive_c/windows/system/iosubsys"
  mkdir -p "$iosub"
  for disc in "$(resolve_disc_root bw_cd || true)" "$(resolve_disc_root sc_cd || true)"; do
    [ -n "$disc" ] || continue
    if [ -d "${disc}/CRACK/UNZIPPED" ]; then
      cp -f "${disc}/CRACK/UNZIPPED/"*.VXD "$iosub/" 2>/dev/null || true
      log "CD VXDs from ${disc}/CRACK/UNZIPPED"
      return 0
    fi
  done
}

mkdir -p "$GAME_DIR"

sc_install="$(resolve_disc_root sc_cd || true)"
bw_install="$(resolve_disc_root bw_cd || true)"
ensure_mpq "/home/commander/sc_assets/StarCraft.mpq" "$GAME_DIR/StarCraft.mpq" "StarCraft.mpq" || \
  ensure_mpq "${sc_install}/INSTALL.EXE" "$GAME_DIR/StarCraft.mpq" "StarCraft.mpq" || true
ensure_mpq "/home/commander/sc_assets/BroodWar.mpq" "$GAME_DIR/BroodWar.mpq" "BroodWar.mpq" || \
  ensure_mpq "${bw_install}/INSTALL.EXE" "$GAME_DIR/BroodWar.mpq" "BroodWar.mpq" || true

for dll in storm.dll battle.snp standard.snp; do
  materialize_file "/home/commander/sc_assets/$dll" "$GAME_DIR/$dll" "$dll" || true
done

materialize_file "/home/commander/sc_assets/StarCraft.exe" "$GAME_DIR/StarCraft.exe" "StarCraft.exe" || true
if [ -f "/home/commander/sc_assets/Brood War.exe" ]; then
  materialize_file "/home/commander/sc_assets/Brood War.exe" "$GAME_DIR/Brood War.exe" "Brood War.exe" || true
elif [ -f "$GAME_DIR/StarCraft.exe" ]; then
  materialize_file "$GAME_DIR/StarCraft.exe" "$GAME_DIR/Brood War.exe" "Brood War.exe" || true
fi

install_cd_vxds
mount_wine_cds
update_registry

ddraw_ini="/opt/ra2/config/starcraft-ddraw.ini"
ddraw_dll="/home/commander/game_assets/ddraw.dll"
if [ -f "$ddraw_ini" ]; then
  cp -f "$ddraw_ini" "$GAME_DIR/ddraw.ini"
  log "refreshed ddraw.ini from ${ddraw_ini}"
fi
if [ -f "$ddraw_dll" ]; then
  cp -f "$ddraw_dll" "$GAME_DIR/ddraw.dll"
  log "refreshed ddraw.dll from ${ddraw_dll}"
fi

if [ ! -f "$GAME_DIR/StarCraft.mpq" ] || [ ! -f "$GAME_DIR/BroodWar.mpq" ]; then
  if [ -f "/home/commander/sc_assets/StarCraft.mpq" ] && [ -f "/home/commander/sc_assets/BroodWar.mpq" ]; then
    log "using no-CD mpq files from sc_assets"
  else
    log "ERROR: StarCraft.mpq and BroodWar.mpq are required (no-CD)"
    exit 1
  fi
fi

log "StarCraft session ready"
