#!/bin/sh
# synology_nas_audit.sh
# Read-only Synology NAS discovery/audit script.
# Target: DSM 7.x / Synology DS225+ style systems.
# Output: timestamped audit folder + compressed tarball under /volume2/Data/_system_audits when available.

set -eu

HOSTNAME_SAFE="$(hostname 2>/dev/null | tr ' /:' '___' || echo synology)"
TS="$(date +%Y%m%d_%H%M%S)"
DEFAULT_BASE="/volume2/Data/_system_audits"
FALLBACK_BASE="/tmp/synology_audits"

if [ -d "/volume2/Data" ] || [ -d "/volume2/@appdata" ] || [ -d "/volume2" ]; then
  BASE_DIR="$DEFAULT_BASE"
else
  BASE_DIR="$FALLBACK_BASE"
fi

OUT_DIR="$BASE_DIR/${HOSTNAME_SAFE}_audit_$TS"
REPORT="$OUT_DIR/SYNOLOGY_NAS_AUDIT_$TS.md"
RAW_DIR="$OUT_DIR/raw"

mkdir -p "$RAW_DIR"

umask 077

log() {
  printf '%s\n' "$*" | tee -a "$REPORT" >/dev/null
}

section() {
  printf '\n## %s\n\n' "$1" >> "$REPORT"
}

run_cmd() {
  NAME="$1"
  shift
  SAFE_NAME="$(printf '%s' "$NAME" | tr ' /:' '___' | tr -cd 'A-Za-z0-9_.-')"
  RAW_FILE="$RAW_DIR/${SAFE_NAME}.txt"

  {
    echo "# $NAME"
    echo "# Command: $*"
    echo "# Captured: $(date -Is 2>/dev/null || date)"
    echo
    "$@"
  } > "$RAW_FILE" 2>&1 || true

  printf '### %s\n\n' "$NAME" >> "$REPORT"
  printf '```text\n' >> "$REPORT"
  sed -n '1,220p' "$RAW_FILE" >> "$REPORT" 2>/dev/null || true
  LINE_COUNT="$(wc -l < "$RAW_FILE" 2>/dev/null | tr -d ' ' || echo 0)"
  if [ "${LINE_COUNT:-0}" -gt 220 ]; then
    printf '\n[truncated in markdown; full output saved at raw/%s.txt]\n' "$SAFE_NAME" >> "$REPORT"
  fi
  printf '```\n\n' >> "$REPORT"
}

run_sh() {
  NAME="$1"
  SCRIPT="$2"
  SAFE_NAME="$(printf '%s' "$NAME" | tr ' /:' '___' | tr -cd 'A-Za-z0-9_.-')"
  RAW_FILE="$RAW_DIR/${SAFE_NAME}.txt"

  {
    echo "# $NAME"
    echo "# Captured: $(date -Is 2>/dev/null || date)"
    echo
    sh -c "$SCRIPT"
  } > "$RAW_FILE" 2>&1 || true

  printf '### %s\n\n' "$NAME" >> "$REPORT"
  printf '```text\n' >> "$REPORT"
  sed -n '1,220p' "$RAW_FILE" >> "$REPORT" 2>/dev/null || true
  LINE_COUNT="$(wc -l < "$RAW_FILE" 2>/dev/null | tr -d ' ' || echo 0)"
  if [ "${LINE_COUNT:-0}" -gt 220 ]; then
    printf '\n[truncated in markdown; full output saved at raw/%s.txt]\n' "$SAFE_NAME" >> "$REPORT"
  fi
  printf '```\n\n' >> "$REPORT"
}

redact_sensitive_files() {
  # Conservative redaction for secrets/tokens/password-looking values in captured raw text.
  # Does not modify the NAS, only audit output files.
  find "$RAW_DIR" -type f -name '*.txt' | while read -r f; do
    sed -i \
      -e 's/\([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd][^=:\"]*[=:\"]\)[^\" ]*/\1[REDACTED]/g' \
      -e 's/\([Tt][Oo][Kk][Ee][Nn][^=:\"]*[=:\"]\)[^\" ]*/\1[REDACTED]/g' \
      -e 's/\([Ss][Ee][Cc][Rr][Ee][Tt][^=:\"]*[=:\"]\)[^\" ]*/\1[REDACTED]/g' \
      -e 's/\([Aa][Pp][Ii]_[Kk][Ee][Yy][^=:\"]*[=:\"]\)[^\" ]*/\1[REDACTED]/g' \
      "$f" 2>/dev/null || true
  done
}

cat > "$REPORT" <<EOF_REPORT
# Synology NAS Audit

- Hostname: $HOSTNAME_SAFE
- Captured: $(date -Is 2>/dev/null || date)
- Output directory: $OUT_DIR
- Script mode: read-only discovery
- Intended data root preference: /volume2/Data

EOF_REPORT

section "Executive Summary Inputs"
run_cmd "Identity" hostname
run_cmd "Current User" id
run_cmd "Uptime" uptime
run_cmd "Kernel" uname -a
run_sh "DSM Version Files" 'cat /etc.defaults/VERSION 2>/dev/null; echo; cat /etc/VERSION 2>/dev/null'
run_sh "Synology Model Info" 'cat /proc/sys/kernel/syno_hw_version 2>/dev/null; echo; cat /proc/cpuinfo 2>/dev/null | sed -n "1,80p"; echo; free -h 2>/dev/null || cat /proc/meminfo 2>/dev/null | sed -n "1,40p"'

section "Storage Layout"
run_cmd "Mounted Filesystems" df -hT
run_cmd "Block Devices" lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT,MODEL,SERIAL
run_cmd "Disk Usage Volume Roots" du -sh /volume* 2>/dev/null
run_sh "Volume Directory Overview" 'for v in /volume*; do [ -d "$v" ] || continue; echo "### $v"; ls -la "$v" | sed -n "1,120p"; echo; done'
run_sh "Data Volume Overview" 'for p in /volume2 /volume2/Data /volume2/docker /volume2/@appdata /volume2/@docker; do if [ -e "$p" ]; then echo "### $p"; ls -la "$p" | sed -n "1,160p"; echo; fi; done'
run_sh "Synology Storage CLI" 'synostgvolume --enum 2>/dev/null; echo; synodisk --enum 2>/dev/null; echo; syno_disk_health_record 2>/dev/null | sed -n "1,120p"'
run_sh "mdadm RAID Status" 'cat /proc/mdstat 2>/dev/null; echo; mdadm --detail /dev/md* 2>/dev/null | sed -n "1,240p"'
run_sh "Btrfs Subvolumes" 'command -v btrfs >/dev/null 2>&1 && btrfs subvolume list /volume1 2>/dev/null; command -v btrfs >/dev/null 2>&1 && btrfs subvolume list /volume2 2>/dev/null'

section "Shared Folders and Permissions"
run_sh "Shared Folder Config" 'cat /etc/synoinfo.conf 2>/dev/null | grep -i share || true; echo; ls -la /var/services 2>/dev/null; echo; find /volume* -maxdepth 1 -mindepth 1 -type d -printf "%p\n" 2>/dev/null | sort'
run_sh "Syno Share CLI" 'synoshare --enum ALL 2>/dev/null; echo; synoshare --get Data 2>/dev/null; echo; synoshare --get docker 2>/dev/null'
run_sh "ACL Snapshot Volume2 Top Level" 'synoacltool -get /volume2 2>/dev/null; echo; synoacltool -get /volume2/Data 2>/dev/null; echo; synoacltool -get /volume2/docker 2>/dev/null'

section "Network, DDNS, VPN, and Firewall"
run_cmd "IP Addresses" ip addr show
run_cmd "Routing Table" ip route show table all
run_cmd "DNS Resolver" cat /etc/resolv.conf
run_sh "Network Interfaces Legacy" 'ifconfig -a 2>/dev/null; echo; brctl show 2>/dev/null'
run_sh "Synology Network Config Files" 'for f in /etc/sysconfig/network-scripts/ifcfg-* /etc.defaults/synoinfo.conf /etc/synoinfo.conf; do [ -f "$f" ] && echo "### $f" && sed -n "1,220p" "$f" && echo; done'
run_sh "DDNS Config Hints" 'find /etc /usr/syno/etc /var/packages -iname "*ddns*" -maxdepth 5 2>/dev/null | sort | sed -n "1,200p"'
run_sh "VPN Config Hints" 'find /etc /usr/syno/etc /var/packages /volume1 /volume2 -iname "*openvpn*" -o -iname "*vpn*" 2>/dev/null | sed -n "1,220p"'
run_sh "Firewall Rules Hints" 'iptables -S 2>/dev/null; echo; iptables -t nat -S 2>/dev/null; echo; nft list ruleset 2>/dev/null | sed -n "1,260p"'

section "Packages and Services"
run_sh "Installed Synology Packages" 'synopkg list 2>/dev/null; echo; ls -la /var/packages 2>/dev/null | sed -n "1,220p"'
run_sh "Running Processes" 'ps auxww 2>/dev/null | sed -n "1,260p"'
run_sh "Listening Ports" 'ss -tulpn 2>/dev/null || netstat -tulpn 2>/dev/null'
run_sh "Systemd Service State" 'systemctl --type=service --state=running 2>/dev/null | sed -n "1,220p"'
run_sh "Synoservice Status" 'synoservice --status 2>/dev/null | sed -n "1,260p"'
run_sh "Scheduled Tasks Cron" 'cat /etc/crontab 2>/dev/null; echo; ls -la /etc/cron* 2>/dev/null; echo; find /usr/syno/etc/synoscheduler /var/packages -maxdepth 5 -type f 2>/dev/null | sed -n "1,220p"'

section "Docker / Container Manager"
run_sh "Docker Version and Info" 'docker version 2>/dev/null; echo; docker info 2>/dev/null'
run_sh "Docker Containers" 'docker ps -a --no-trunc 2>/dev/null'
run_sh "Docker Images" 'docker images --digests 2>/dev/null'
run_sh "Docker Networks" 'docker network ls 2>/dev/null; echo; for n in $(docker network ls --format "{{.Name}}" 2>/dev/null); do echo "### network $n"; docker network inspect "$n" 2>/dev/null; done'
run_sh "Docker Volumes" 'docker volume ls 2>/dev/null; echo; for v in $(docker volume ls --format "{{.Name}}" 2>/dev/null); do echo "### volume $v"; docker volume inspect "$v" 2>/dev/null; done'
run_sh "Docker Compose Files Search" 'find /volume1 /volume2 -maxdepth 8 \( -iname "docker-compose.yml" -o -iname "docker-compose.yaml" -o -iname "compose.yml" -o -iname "compose.yaml" -o -iname ".env" \) 2>/dev/null | sort | sed -n "1,300p"'
run_sh "qBittorrent Gluetun Containers Inspect" 'for c in $(docker ps -a --format "{{.Names}}" 2>/dev/null | grep -Ei "qbittorrent|gluetun|vpn|torrent"); do echo "### container $c"; docker inspect "$c" 2>/dev/null; echo; done'

section "Download Station and Media Apps"
run_sh "Download Station Package Layout" 'for p in /var/packages/DownloadStation /volume*/@appstore/DownloadStation /volume*/@appdata/DownloadStation; do [ -e "$p" ] && echo "### $p" && find "$p" -maxdepth 3 -print 2>/dev/null | sed -n "1,220p"; done'
run_sh "Download Related Processes" 'ps auxww 2>/dev/null | grep -Ei "DownloadStation|download|bt|torrent|qbittorrent|gluetun" | grep -v grep || true'

section "Users, Groups, and Access"
run_sh "Users" 'cat /etc/passwd 2>/dev/null | sed -n "1,220p"'
run_sh "Groups" 'cat /etc/group 2>/dev/null | sed -n "1,220p"'
run_sh "SSH Config Hints" 'grep -Ev "^#|^$" /etc/ssh/sshd_config 2>/dev/null | sed -n "1,180p"; echo; ls -la ~/.ssh 2>/dev/null'

section "Recent Logs and Health Hints"
run_sh "Recent System Messages" 'for f in /var/log/messages /var/log/synolog/synoservice.log /var/log/synopkg.log; do [ -f "$f" ] && echo "### $f" && tail -n 180 "$f" && echo; done'
run_sh "SMART Summary" 'for d in /dev/sd? /dev/nvme?n?; do [ -e "$d" ] || continue; echo "### $d"; smartctl -H "$d" 2>/dev/null; smartctl -A "$d" 2>/dev/null | sed -n "1,80p"; echo; done'

# Redact after collection, then rebuild a compact redaction note into report footer.
redact_sensitive_files

cat >> "$REPORT" <<EOF_REPORT

## Notes

- This audit is read-only. It should not alter routing, packages, Docker, shares, or firewall rules.
- Raw command outputs are saved in ./raw next to this report.
- Password/token/secret-looking strings are redacted in raw text files where detected.
- Review output before sharing externally because paths, usernames, LAN IPs, public IPs, DDNS names, container names, and share names can still be sensitive.

EOF_REPORT

# Recreate markdown snippets after redaction is intentionally not done, because report was generated before redaction.
# To keep the markdown report from containing unredacted secrets, apply the same redaction to it too.
sed -i \
  -e 's/\([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd][^=:\"]*[=:\"]\)[^\" ]*/\1[REDACTED]/g' \
  -e 's/\([Tt][Oo][Kk][Ee][Nn][^=:\"]*[=:\"]\)[^\" ]*/\1[REDACTED]/g' \
  -e 's/\([Ss][Ee][Cc][Rr][Ee][Tt][^=:\"]*[=:\"]\)[^\" ]*/\1[REDACTED]/g' \
  -e 's/\([Aa][Pp][Ii]_[Kk][Ee][Yy][^=:\"]*[=:\"]\)[^\" ]*/\1[REDACTED]/g' \
  "$REPORT" 2>/dev/null || true

TARBALL="$BASE_DIR/${HOSTNAME_SAFE}_audit_$TS.tar.gz"
tar -czf "$TARBALL" -C "$BASE_DIR" "${HOSTNAME_SAFE}_audit_$TS" 2>/dev/null || true

printf '\nAudit complete.\n'
printf 'Report: %s\n' "$REPORT"
printf 'Raw output folder: %s\n' "$RAW_DIR"
[ -f "$TARBALL" ] && printf 'Archive: %s\n' "$TARBALL"
