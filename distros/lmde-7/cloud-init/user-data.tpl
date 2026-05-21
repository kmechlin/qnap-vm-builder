#cloud-config
hostname: ${VMHOSTNAME}
manage_etc_hosts: true

users:
  - name: ${USERNAME}
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: false
    # Hash MUST live on the user record. Putting it only in chpasswd: makes
    # cloud-init warn ("Not unlocking password for user … no passwd/hashed_passwd
    # provided in user data") and leave the account locked from useradd's
    # default — which means console/SSH login as this user fails and you
    # have to fall back to the baked root password.
    hashed_passwd: "${PWHASH}"

# Expire the password so the FIRST login forces a reset.
chpasswd:
  expire: true

ssh_pwauth: true

package_update: true
package_upgrade: true

packages:
  # --- full Debian kernel for desktop GPU drivers ---
  # The genericcloud base ships linux-image-cloud-amd64, which strips out
  # qxl/virtio_gpu/i915/etc. Without qxl, /sys/class/drm/card0 never
  # appears, logind reports seat0 as non-graphical, and lightdm sits idle
  # forever — the GUI just never starts. linux-image-amd64 pulls the full
  # module set; grub picks it as the default on next boot.
  - linux-image-amd64
  # --- Cinnamon (LMDE-feel desktop, from Debian trixie main) ---
  # The meta-package pulls cinnamon, muffin (its compositor), nemo, themes,
  # and lightdm. No Mint apt repo needed — LMDE 7 ships almost the same set.
  - cinnamon-desktop-environment
  - dbus-x11
  # --- video + guest tools tuned for VS web console (QXL + SPICE + virtio) ---
  - xserver-xorg-video-qxl
  - spice-vdagent
  - qemu-guest-agent
  # --- minimum utilities the runcmd steps below need (curl/gpg for VS Code
  # + Chrome repo setup; ca-certificates so https works; cloud-utils for
  # cloud-init's own resize machinery) ---
  - curl
  - ca-certificates
  - gpg
  - cloud-utils

runcmd:
  # --- swap cloud kernel for full kernel ---
  # linux-image-amd64 was pulled in via `packages:` above, but the cloud
  # kernel is still installed and grub keeps it as menu entry 0. Purge it
  # so grub has only the full kernel; the power_state: reboot at the end
  # of cloud-init then lands us on it with qxl available.
  - DEBIAN_FRONTEND=noninteractive apt-get purge -y linux-image-cloud-amd64 'linux-image-*+deb13-cloud-amd64'
  - update-grub
  # --- pin qxl autoload ---
  # On UEFI guests, efifb grabs the QXL PCI device early in boot and qxl
  # sometimes can't take over via udev modalias matching alone. Force it
  # via systemd-modules-load so the DRM card always appears for seat0.
  - 'echo qxl > /etc/modules-load.d/qxl.conf'

  # --- pre-create lightdm data dir ---
  # The lightdm package's postinst sometimes skips this under cloud-init's
  # noninteractive apt, which spams "Could not enumerate user data directory
  # /var/lib/lightdm/data" in the journal on every start. Harmless but noisy.
  - install -d -o lightdm -g lightdm -m 0750 /var/lib/lightdm/data

  # --- Cinnamon session + lightdm autologin to the dev user ---
  - echo "cinnamon-session" > /home/${USERNAME}/.xsession
  - chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.xsession
  - install -d /etc/lightdm/lightdm.conf.d
  - printf '[Seat:*]\nautologin-user=${USERNAME}\nautologin-session=cinnamon\nuser-session=cinnamon\n' > /etc/lightdm/lightdm.conf.d/50-autologin.conf
  - systemctl set-default graphical.target
  - systemctl enable --now lightdm || true
  - systemctl enable --now spice-vdagentd || true
  - systemctl enable --now qemu-guest-agent || true

  # --- Cinnamon performance tuning for the SPICE console ---
  # Compositor effects, animations, fade transitions, and the screensaver
  # all hurt perceived latency on a remote console. Drop a system-wide
  # dconf override so every user gets the snappy defaults; no per-user
  # gsettings dance needed.
  - |
    install -d /etc/dconf/db/local.d /etc/dconf/profile
    cat > /etc/dconf/db/local.d/00-cinnamon-perf <<'DCONF'
    [org/cinnamon/muffin]
    desktop-effects=false
    unredirect-fullscreen-windows=true

    [org/cinnamon]
    startup-animation=false
    enable-vfade=false
    desktop-effects-on-dialogs=false
    desktop-effects-on-menus=false

    [org/cinnamon/desktop/interface]
    enable-animations=false

    [org/cinnamon/desktop/screensaver]
    lock-enabled=false
    idle-activation-enabled=false

    [org/cinnamon/settings-daemon/plugins/power]
    sleep-display-ac=0
    sleep-inactive-ac-timeout=0
    DCONF
    printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user
    dconf update

  # --- register custom xrandr modes for ultrawide / QHD monitors ---
  # QXL ships modes only up to 2560x1600 16:10. Register 2560x1080 (21:9
  # ultrawide) and 2560x1440 (16:9 QHD) so they appear in Cinnamon's
  # Display settings. Anything taller at >=2560 wide exceeds the QXL VRAM
  # budget VS gives the device, so this is the practical maximum.
  #
  # Drop into ~/.xsessionrc (NOT .xprofile): on Debian, the X session
  # wrapper at /etc/X11/Xsession.d/40x11-common_xsessionrc sources
  # ~/.xsessionrc and ignores ~/.xprofile. Using the wrong name silently
  # leaves the modes unregistered until the user re-runs the script.
  - |
    cat > /home/${USERNAME}/.xsessionrc <<'XSRC'
    xrandr --newmode "2560x1080_60.00" 230.00 2560 2720 2992 3424 1080 1083 1093 1120 -hsync +vsync 2>/dev/null || true
    xrandr --addmode Virtual-1 "2560x1080_60.00" 2>/dev/null || true
    xrandr --newmode "2560x1440_60.00" 312.25 2560 2752 3024 3488 1440 1443 1448 1493 -hsync +vsync 2>/dev/null || true
    xrandr --addmode Virtual-1 "2560x1440_60.00" 2>/dev/null || true
    XSRC
  - chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.xsessionrc
  - chmod 0755 /home/${USERNAME}/.xsessionrc

  # --- VS Code (Microsoft apt repo) ---
  - install -d -m 0755 /etc/apt/keyrings
  - 'curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg'
  - 'echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list'

  # --- Google Chrome ---
  - 'curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg'
  - 'echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list'

  - apt-get update
  - DEBIAN_FRONTEND=noninteractive apt-get install -y code google-chrome-stable

  # --- Claude Code (native installer, per-user; no Node.js dependency) ---
  - su - ${USERNAME} -c 'curl -fsSL https://claude.ai/install.sh | bash'

final_message: "cloud-init done. SSH in as ${USERNAME} (initial password) to reset it, then use the QNAP web console for the desktop."

# Reboot once cloud-init finishes so the full kernel (with qxl) takes
# effect and Cinnamon comes up with the dconf-tuned defaults applied.
power_state:
  mode: reboot
  delay: now
  message: "cloud-init done — rebooting"
