#!/bin/sh
# Run inside ra2-player-1 before Brood War SETUP (or after base StarCraft install).
# Maps Wine CD drives, copies INSTALL.EXE → *.mpq, and installs CD VXDs so the
# Brood War wizard can find the base StarCraft disc.
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

PLAYER="${RA2_ULTRA_SERVICE:-ra2-player-1}"

run_docker exec -u commander "$PLAYER" /bin/sh -c '
set -eu
SC="/home/commander/.wine/drive_c/Starcraft"
IOSUB="/home/commander/.wine/drive_c/windows/system/iosubsys"
export WINEDLLOVERRIDES=mscoree=d;mshtml=d;comctl32=b

[ -d "$SC" ] || { echo "[sc-prepare] StarCraft not installed at $SC"; exit 1; }
[ -f /tmp/sc_install_sc/INSTALL.EXE ] || { echo "[sc-prepare] missing /tmp/sc_install_sc"; exit 1; }
[ -f /tmp/sc_install_bw/INSTALL.EXE ] || { echo "[sc-prepare] missing /tmp/sc_install_bw"; exit 1; }

wineserver -k >/dev/null 2>&1 || true
sleep 2

rm -f /home/commander/.wine/dosdevices/d: /home/commander/.wine/dosdevices/e:
ln -sf /tmp/sc_install_sc /home/commander/.wine/dosdevices/d:
ln -sf /tmp/sc_install_bw /home/commander/.wine/dosdevices/e:

mkdir -p "$IOSUB"
cp -f /tmp/sc_install_bw/CRACK/UNZIPPED/*.VXD "$IOSUB/"

cp -f /tmp/sc_install_sc/INSTALL.EXE "$SC/StarCraft.mpq"
cp -f /tmp/sc_install_bw/INSTALL.EXE "$SC/BroodWar.mpq"

wine reg add "HKLM\\Software\\Blizzard Entertainment\\Starcraft" /v StarCD /t REG_SZ /d "D:\\" /f

echo "[sc-prepare] StarCD=D:\\ (base disc at /tmp/sc_install_sc)"
echo "[sc-prepare] CD VXDs installed under windows/system/iosubsys"
echo "[sc-prepare] StarCraft.mpq + BroodWar.mpq updated under $SC"
'
