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
  cat <<'GRUBCFG' >"${MOUNT}/boot/grub/grub.cfg"
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
# This handles the special "Superfloppy + MBR" layout where partition 1 starts at LBA 0.
# sfdisk rejects "start=0" as invalid, so we must binary-patch the MBR partition table.

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

# Get total size of the disk in sectors
TOTAL_SECTORS=$(cat "/sys/class/block/$(basename ${DISK})/size")
echo "Detected disk size: ${TOTAL_SECTORS} sectors"

# Convert to 4-byte little endian hex for MBR
printf -v S_HEX "%08x" "${TOTAL_SECTORS}"
S0="${S_HEX:6:2}"
S1="${S_HEX:4:2}"
S2="${S_HEX:2:2}"
S3="${S_HEX:0:2}"

# Construct the 16-byte partition entry (Offset 446)
# Byte 0:    0x80 (Bootable)
# Byte 1-3:  0x00 0x01 0x00 (CHS Start: Head 0, Sector 1, Cylinder 0)
# Byte 4:    0x83 (Linux Type)
# Byte 5-7:  0xFE 0xFF 0xFF (CHS End: Max)
# Byte 8-11: 0x00 0x00 0x00 0x00 (LBA Start: 0 - CRITICAL for Superfloppy)
# Byte 12-15: Size in sectors (Little Endian)
PART_ENTRY="\x80\x00\x01\x00\x83\xfe\xff\xff\x00\x00\x00\x00\x${S0}\x${S1}\x${S2}\x${S3}"

echo "Patching MBR partition table..."
printf "${PART_ENTRY}" | dd of="${DISK}" bs=1 seek=446 count=16 conv=notrunc

# Force kernel to update partition table info
# partx -u is generally safer for live partitions than partprobe
echo "Updating kernel partition table..."
partx -u "${DISK}" || partprobe "${DISK}" || true

# Resize filesystem
echo "Resizing filesystem..."
resize2fs "${DISK}${PART}"

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
