#!/bin/bash

# Misc "tweaks" done after bootstrapping
function pre() {
  # Remove machine-id see:
  # https://gitlab.archlinux.org/archlinux/arch-boxes/-/issues/25
  # https://gitlab.archlinux.org/archlinux/arch-boxes/-/issues/117
  rm "${MOUNT}/etc/machine-id"

  # fstab — superfloppy: root filesystem is /dev/vda (no partition)
  echo "/dev/vda / ext4 rw,relatime 0 1" >>"${MOUNT}/etc/fstab"

  # Swap
  mkdir -p "${MOUNT}/swap"
  chmod 0700 "${MOUNT}/swap"
  dd if=/dev/zero of="${MOUNT}/swap/swapfile" bs=1M count=2048 status=none
  chmod 0600 "${MOUNT}/swap/swapfile"
  mkswap "${MOUNT}/swap/swapfile" >/dev/null
  echo "/swap/swapfile none swap defaults 0 0" >>"${MOUNT}/etc/fstab"

  arch-chroot "${MOUNT}" /usr/bin/systemd-firstboot --locale=C.UTF-8 --timezone=UTC --hostname=archlinux --keymap=us
  ln -sf /run/systemd/resolve/stub-resolv.conf "${MOUNT}/etc/resolv.conf"

  # Setup pacman-init.service for clean pacman keyring initialization
  cat <<EOF >"${MOUNT}/etc/systemd/system/pacman-init.service"
[Unit]
Description=Initializes Pacman keyring
Before=sshd.service cloud-final.service archlinux-keyring-wkd-sync.service
After=time-sync.target
ConditionFirstBoot=yes

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/pacman-key --init
ExecStart=/usr/bin/pacman-key --populate

[Install]
WantedBy=multi-user.target
EOF

  # Setup mirror list to worldwide mirrors
  cat <<'EOF' >"${MOUNT}/etc/pacman.d/mirrorlist"
Server = https://fastly.mirror.pkgbuild.com/$repo/os/$arch
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
EOF

  # enabling important services
  arch-chroot "${MOUNT}" /bin/bash -e <<EOF
source /etc/profile
systemctl enable sshd
systemctl enable systemd-networkd
systemctl enable systemd-resolved
systemctl enable systemd-timesyncd
systemctl enable systemd-time-wait-sync
systemctl enable pacman-init.service
EOF

  # Default access policy for cloud builds: keep root and allow password login.
  echo "root:A2vL5Y1hZ9" | arch-chroot "${MOUNT}" /usr/bin/chpasswd
  arch-chroot "${MOUNT}" /usr/bin/chage -I -1 -m 0 -M 99999 -E -1 root

  mkdir -p "${MOUNT}/etc/ssh/sshd_config.d"
  cat <<EOF >"${MOUNT}/etc/ssh/sshd_config.d/10-password-login.conf"
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PermitRootLogin yes
EOF

  mkdir -p "${MOUNT}/etc/cloud/cloud.cfg.d"
  cat <<EOF >"${MOUNT}/etc/cloud/cloud.cfg.d/99-enable-password-login.cfg"
disable_root: false
ssh_pwauth: true
chpasswd:
  expire: false
EOF

  # GRUB — Superfloppy: host GRUB reads (hd0)/boot/grub/grub.cfg directly.
  # No grub-install needed (host provides MBR bootloader).
  # Configure /etc/default/grub so 'grub-mkconfig' works on the live VPS.
  sed -i 's/^GRUB_TIMEOUT=.*$/GRUB_TIMEOUT=1/' "${MOUNT}/etc/default/grub"
  sed -i 's/^GRUB_CMDLINE_LINUX=.*$/GRUB_CMDLINE_LINUX="net.ifnames=0"/' "${MOUNT}/etc/default/grub"
  sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"\"/' "${MOUNT}/etc/default/grub"
  echo 'GRUB_DISABLE_LINUX_UUID=true' >>"${MOUNT}/etc/default/grub"
  echo 'GRUB_DISABLE_LINUX_PARTUUID=true' >>"${MOUNT}/etc/default/grub"

  # Write static grub.cfg (cloud-image.sh will overwrite with serial console).
  mkdir -p "${MOUNT}/boot/grub"
  cat <<'GRUBCFG' >"${MOUNT}/boot/grub/grub.cfg"
insmod ext2
set root=(hd0)
set timeout=1
set default=0

menuentry "Arch Linux" {
    linux /boot/vmlinuz-linux root=/dev/vda rw net.ifnames=0
    initrd /boot/initramfs-linux.img
}

menuentry "Arch Linux (fallback)" {
    linux /boot/vmlinuz-linux root=/dev/vda rw net.ifnames=0
    initrd /boot/initramfs-linux-fallback.img
}
GRUBCFG
}
