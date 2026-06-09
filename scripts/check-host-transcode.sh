#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
FAIL=0

check_pass() {
  printf '[OK] %s\n' "$1"
}

check_fail() {
  printf '[FAIL] %s\n' "$1"
  FAIL=1
}

check_warn() {
  printf '[WARN] %s\n' "$1"
}

printf 'Checking Synology host i915 media engine state\n\n'

if uname -a | grep -q synology_geminilakenk; then
  check_pass "host platform is Gemini Lake (DS225+/DS425+ family)"
else
  check_warn "host platform is not synology_geminilakenk; DS225+ fixes may not apply"
fi

if [ -d /dev/dri ] && [ -c /dev/dri/renderD128 ]; then
  check_pass "host exposes /dev/dri/renderD128"
else
  check_fail "host render node is missing"
fi

if [ -r /sys/module/i915/parameters/enable_guc ]; then
  guc="$(sed -n '1p' /sys/module/i915/parameters/enable_guc 2>/dev/null || true)"
  case "$guc" in
    0)
      check_fail "i915 enable_guc=0 (Synology default; VA-API encode stays disabled)"
      ;;
    *)
      check_pass "i915 enable_guc=$guc"
      ;;
  esac
else
  check_fail "i915 module parameters are unavailable"
fi

if [ -r /sys/kernel/debug/dri/0/gt/uc/guc_info ]; then
  if grep -q 'GuC disabled' /sys/kernel/debug/dri/0/gt/uc/guc_info 2>/dev/null; then
    check_fail "GuC is disabled on the host GPU firmware path"
  else
    check_pass "GuC is active on the host"
  fi
else
  check_warn "debugfs GuC info is unavailable (run as root)"
fi

if [ -r /sys/kernel/debug/dri/0/gt/uc/huc_info ]; then
  if grep -q 'HuC disabled' /sys/kernel/debug/dri/0/gt/uc/huc_info 2>/dev/null; then
    check_fail "HuC is disabled on the host GPU firmware path"
  else
    check_pass "HuC is active on the host"
  fi
fi

guc_fw_count="$(ls /lib/firmware/i915 2>/dev/null | grep -Eic 'guc|huc' || true)"
if [ "$guc_fw_count" -eq 0 ]; then
  check_warn "no GuC/HuC firmware blobs in /lib/firmware/i915"
else
  check_pass "GuC/HuC firmware blobs are present ($guc_fw_count files)"
fi

if [ "$FAIL" -ne 0 ]; then
  printf '\nHost fix:\n'
  printf '  sudo sh %s/enable-host-transcode.sh\n' "$SCRIPT_DIR"
  printf '  or install Transcode_for_x25 from Package Center and schedule it at boot\n'
  exit 1
fi

printf '\nHost i915 media engine looks ready for container VA-API probes.\n'
exit 0
