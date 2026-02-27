#!/bin/bash
# shellcheck disable=SC2034,SC2154
IMAGE_NAME="Arch-Linux-x86_64-cloudimg-${build_version}.raw"
DISK_SIZE=""
# The growpart module requires cloud-guest-utils.
# [1] https://cloudinit.readthedocs.io/en/latest/reference/modules.html#growpart
PACKAGES=(cloud-init cloud-guest-utils)
SERVICES=(cloud-init-main.service cloud-init-local.service cloud-init-network.service cloud-config.service cloud-final.service)

function pre() {
# Disable growpart/resizefs — handled by our oneshot expand-disk.service
  mkdir -p "${MOUNT}/etc/cloud/cloud.cfg.d"
  cat <<'EOF' >"${MOUNT}/etc/cloud/cloud.cfg.d/99-disable-growpart.cfg"
growpart:
  mode: off
resize_rootfs: false
EOF

  # GRUB config — console=tty0 only (noVNC visible).
  cat <<'GRUBCFG' >"${MOUNT}/boot/grub/grub.cfg"
set root=(hd0,msdos1)
set timeout=1
set default=0

menuentry "Arch Linux" {
    linux /boot/vmlinuz-linux root=/dev/vda1 rw net.ifnames=0 console=tty0
    initrd /boot/initramfs-linux.img
}

menuentry "Arch Linux (fallback)" {
    linux /boot/vmlinuz-linux root=/dev/vda1 rw net.ifnames=0 console=tty0
    initrd /boot/initramfs-linux-fallback.img
}
GRUBCFG
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

  gzip -1 -c "${raw_image}" > "${raw_image}.gz"
}
