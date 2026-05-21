#!/usr/bin/env bash
# bootstrap.sh — lean Debian 13 dev box: XFCE + xrdp + VS Code + Chrome + Claude Code.
# Use this instead of cloud-init when you did a normal Debian 13 install.
# Run:  sudo bash bootstrap.sh
#
# Note: xrdp authenticates against the system password, so make sure the login
# user has one set:  sudo passwd <user>

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo:  sudo bash $0" >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
export DEBIAN_FRONTEND=noninteractive

echo ">> Updating base system..."
apt-get update
apt-get -y full-upgrade

echo ">> Installing desktop, remote access, and guest agents..."
apt-get install -y \
  xfce4 xfce4-terminal dbus-x11 \
  xorgxrdp xrdp \
  spice-vdagent qemu-guest-agent \
  curl ca-certificates gpg

install -d -m 0755 /etc/apt/keyrings

echo ">> Adding VS Code repo..."
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
  | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
  > /etc/apt/sources.list.d/vscode.list

echo ">> Adding Google Chrome repo..."
curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
  | gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
  > /etc/apt/sources.list.d/google-chrome.list

echo ">> Installing VS Code + Chrome..."
apt-get update
apt-get install -y code google-chrome-stable

echo ">> Configuring xrdp session..."
echo "startxfce4" > "$TARGET_HOME/.xsession"
chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.xsession"
adduser xrdp ssl-cert || true
systemctl enable --now xrdp
systemctl enable --now spice-vdagentd || true
systemctl enable --now qemu-guest-agent || true

echo ">> Installing Claude Code (native installer, no Node.js)..."
if [[ "$TARGET_USER" != "root" ]]; then
  sudo -u "$TARGET_USER" -H bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
else
  curl -fsSL https://claude.ai/install.sh | bash
fi

cat <<EOF

=== Done ===
 - Ensure a password is set for RDP login:   sudo passwd $TARGET_USER
 - RDP to this VM's IP on port 3389, log in as $TARGET_USER (default kmechlin).
 - Run 'claude' once to authenticate (browser OAuth).
 - VS Code Remote-SSH from your laptop is the lighter alternative to RDP.
EOF
