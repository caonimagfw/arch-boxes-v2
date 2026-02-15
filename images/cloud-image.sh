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
  # Write to /boot/grub2/grub.cfg (real file); /boot/grub is a symlink.
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

  # Grub Legacy config with serial console.
  cat <<'LEGACYCFG' >"${MOUNT}/boot/grub2/grub.conf"
default 0
timeout 1

title Arch Linux
root (hd0,0)
kernel /boot/vmlinuz-linux root=/dev/vda1 rw net.ifnames=0 console=tty0 console=ttyS0,115200
initrd /boot/initramfs-linux.img
LEGACYCFG
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
