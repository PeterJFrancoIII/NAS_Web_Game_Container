#!/bin/sh
# Enable passwordless sudo for the current SSH user on Synology DSM.
# Run once on the NAS (will prompt for your DSM password once):
#   sudo sh scripts/enable-passwordless-sudo.sh
#
# Or from your Mac:
#   ssh -t MediaServer2 'cd /volume2/Data/App_Development/ra2-lan-party/project && sudo sh scripts/enable-passwordless-sudo.sh'
set -eu

USER_NAME="${SUDO_USER:-${USER:-$(id -un)}}"
SUDOERS_FILE="/etc/sudoers.d/${USER_NAME}-nopasswd"
SUDOERS_LINE="${USER_NAME} ALL=(ALL) NOPASSWD: ALL"

if [ "$(id -u)" -ne 0 ]; then
  echo "Re-run with sudo: sudo sh scripts/enable-passwordless-sudo.sh"
  exit 1
fi

if [ -f "$SUDOERS_FILE" ] && grep -Fq "$SUDOERS_LINE" "$SUDOERS_FILE"; then
  echo "OK: passwordless sudo already configured for ${USER_NAME}"
  exit 0
fi

if ! grep -q '^#includedir /etc/sudoers.d' /etc/sudoers 2>/dev/null \
  && ! grep -q '^@includedir /etc/sudoers.d' /etc/sudoers 2>/dev/null; then
  echo "ERROR: /etc/sudoers does not include /etc/sudoers.d — aborting."
  exit 1
fi

mkdir -p /etc/sudoers.d
printf '%s\n' "$SUDOERS_LINE" >"$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"
chown root:root "$SUDOERS_FILE"

if command -v visudo >/dev/null 2>&1; then
  visudo -cf "$SUDOERS_FILE"
fi

echo "OK: passwordless sudo enabled for ${USER_NAME}"
echo "Verify from an SSH session: sudo -n true && echo success"
