#!/bin/sh
# preseed/late_command for the t3-worker installer (busybox, runs before the
# first boot). Copies the setup repository and the Mac's SSH key into the new
# system, hardens SSH and enables the first-boot setup unit.
set -e

SRC=/cdrom/t3-worker
T=/target
USER_NAME=leander

# Setup repository (embedded by make-stick.sh, no network needed)
mkdir -p "$T/opt/t3-worker"
cp -a "$SRC/repo/." "$T/opt/t3-worker/"
chmod 0755 "$T/opt/t3-worker/setup.sh" "$T/opt/t3-worker/lib/"*.sh

# SSH public key of the Mac -> key-only login
mkdir -p "$T/home/$USER_NAME/.ssh"
cp "$SRC/authorized_keys" "$T/home/$USER_NAME/.ssh/authorized_keys"
chmod 0700 "$T/home/$USER_NAME/.ssh"
chmod 0600 "$T/home/$USER_NAME/.ssh/authorized_keys"
in-target chown -R "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.ssh"

mkdir -p "$T/etc/ssh/sshd_config.d"
cp "$T/opt/t3-worker/config/sshd-t3-worker.conf" "$T/etc/ssh/sshd_config.d/10-t3-worker.conf"

# Wi-Fi credentials written by netcfg must not be world-readable
if [ -f "$T/etc/network/interfaces" ] && grep -q 'wpa-' "$T/etc/network/interfaces"; then
    chmod 0600 "$T/etc/network/interfaces"
fi

# First boot: fetch the current repo from GitHub (fallback: this copy) and run
# the non-interactive setup phases once
mkdir -p "$T/usr/local/sbin"
cp "$T/opt/t3-worker/lib/firstboot.sh" "$T/usr/local/sbin/t3-worker-firstboot"
chmod 0755 "$T/usr/local/sbin/t3-worker-firstboot"
ln -sf /opt/t3-worker/setup.sh "$T/usr/local/sbin/t3-worker-setup"
cp "$T/opt/t3-worker/systemd/t3-worker-firstboot.service" "$T/etc/systemd/system/"
in-target systemctl enable t3-worker-firstboot.service

echo "installed $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$T/opt/t3-worker/.installed-from-stick"
exit 0
