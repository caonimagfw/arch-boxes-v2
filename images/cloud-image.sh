#!/bin/bash
# shellcheck disable=SC2034,SC2154
IMAGE_NAME="Arch-Linux-x86_64-cloudimg-${build_version}.raw"
DISK_SIZE=""
# The growpart module requires cloud-guest-utils.
# [1] https://cloudinit.readthedocs.io/en/latest/reference/modules.html#growpart
PACKAGES=(cloud-init cloud-guest-utils)
SERVICES=(cloud-init-main.service cloud-init-local.service cloud-init-network.service cloud-config.service cloud-final.service)

function pre() {
  # Configure /etc/default/grub for future 'grub-mkconfig' on the live VPS.
  sed -Ei 's/^(GRUB_CMDLINE_LINUX_DEFAULT=.*)"$/\1 console=tty0 console=ttyS0,115200"/' "${MOUNT}/etc/default/grub"
  echo 'GRUB_TERMINAL="serial console"' >>"${MOUNT}/etc/default/grub"
  echo 'GRUB_SERIAL_COMMAND="serial --speed=115200"' >>"${MOUNT}/etc/default/grub"

  # GRUB 2 config with serial console for CloudCone VNC/serial.
  # The host expects /boot/grub2/grub.cfg.
  mkdir -p "${MOUNT}/boot/grub2"
  cat <<'GRUBCFG' >"${MOUNT}/boot/grub2/grub.cfg"
set root=(hd0,msdos1)
set timeout=1
set default=0

serial --speed=115200
terminal_input serial console
terminal_output serial console

menuentry "Arch Linux" {
    linux /boot/vmlinuz-linux root=/dev/vda1 rw net.ifnames=0 console=tty0 console=ttyS0,115200
    initrd /boot/initramfs-linux.img
}

menuentry "Arch Linux (fallback)" {
    linux /boot/vmlinuz-linux root=/dev/vda1 rw net.ifnames=0 console=tty0 console=ttyS0,115200
    initrd /boot/initramfs-linux-fallback.img
}
GRUBCFG
  
  # Ensure /boot/grub/grub.cfg also exists as a symlink or file, just in case
  mkdir -p "${MOUNT}/boot/grub"
  ln -sf ../grub2/grub.cfg "${MOUNT}/boot/grub/grub.cfg"

  # Grub Legacy config with serial console.
  cat <<'LEGACYCFG' >"${MOUNT}/boot/grub/grub.conf"
default 0
timeout 1

title Arch Linux
root (hd0,0)
kernel /boot/vmlinuz-linux root=/dev/vda1 rw net.ifnames=0 console=tty0 console=ttyS0,115200
initrd /boot/initramfs-linux.img
LEGACYCFG

  # Install auto-expand script for first boot
  cat <<'EXPANDSCRIPT' >"${MOUNT}/usr/local/bin/expand-root.sh"
#!/bin/bash
# Expand the root partition to fill the disk on first boot.
#
# This uses standard tools (growpart) to resize the partition and filesystem.

set -u
set -e

LOCKFILE="/var/lib/arch-boxes/expand-root-done"
DISK="/dev/vda"
PART="1"

if [ -f "${LOCKFILE}" ]; then
    exit 0
fi

if [ ! -b "${DISK}" ]; then
    echo "Device ${DISK} not found, skipping expansion."
    exit 0
fi

echo "Expanding root partition..."

# Use standard growpart to resize the partition
if command -v growpart >/dev/null; then
    echo "Running growpart..."
    # growpart returns 0 if changed, 1 if no change needed, 2 if error
    growpart "${DISK}" "${PART}" || true
else
    echo "growpart not found, skipping partition resize."
fi

# Resize the filesystem
echo "Resizing filesystem..."
resize2fs "${DISK}${PART}" || true

# Mark as done
mkdir -p "$(dirname "${LOCKFILE}")"
touch "${LOCKFILE}"
echo "Root expansion complete."
EXPANDSCRIPT
  chmod +x "${MOUNT}/usr/local/bin/expand-root.sh"

  # Install systemd service for auto-expand
  cat <<'EXPANDSERVICE' >"${MOUNT}/etc/systemd/system/expand-root.service"
[Unit]
Description=Expand root partition on first boot
After=local-fs.target
Wants=local-fs.target
ConditionPathExists=!/var/lib/arch-boxes/expand-root-done
Before=cloud-init-local.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/expand-root.sh
RemainAfterExit=true
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
EXPANDSERVICE

  # Enable the service
  arch-chroot "${MOUNT}" systemctl enable expand-root.service
}

function post() {
  local raw_image tar_image
  raw_image="${2}"
  tar_image="${2%.raw}.tar"

  mv "${1}" "${raw_image}"
  zstd -T0 -19 --rm "${raw_image}" -o "${raw_image}.zst"
  zstd -d --stdout "${raw_image}.zst" > "${raw_image}"

  tar -cf "${tar_image}" "$(basename "${raw_image}")"
  zstd -T0 -19 --rm "${tar_image}" -o "${tar_image}.zst"
}
