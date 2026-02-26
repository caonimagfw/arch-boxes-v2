#!/bin/bash

# Misc "tweaks" done after bootstrapping
function pre() {
  # Remove machine-id see:
  # https://gitlab.archlinux.org/archlinux/arch-boxes/-/issues/25
  # https://gitlab.archlinux.org/archlinux/arch-boxes/-/issues/117
  rm "${MOUNT}/etc/machine-id"

  # fstab
  echo "/dev/vda1 / ext4 rw,relatime 0 1" >>"${MOUNT}/etc/fstab"

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
systemctl enable expand-disk.service
EOF

  # Default access policy for cloud builds: keep root and allow password login.
  echo "root:Passw0rd" | arch-chroot "${MOUNT}" /usr/bin/chpasswd
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

  # GRUB — Standard BIOS/MBR self-boot.
  # grub-install writes boot.img into MBR and core.img into the post-MBR gap.
  # We then write a static grub.cfg. /etc/default/grub is configured so that
  # 'grub-mkconfig' on the live VPS produces correct output.

  # Configure /etc/default/grub for future 'grub-mkconfig' on the live VPS.
  sed -i 's/^GRUB_TIMEOUT=.*$/GRUB_TIMEOUT=1/' "${MOUNT}/etc/default/grub"
  sed -i 's/^GRUB_CMDLINE_LINUX=.*$/GRUB_CMDLINE_LINUX="net.ifnames=0"/' "${MOUNT}/etc/default/grub"
  sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"\"/' "${MOUNT}/etc/default/grub"
  echo 'GRUB_DISABLE_LINUX_UUID=true' >>"${MOUNT}/etc/default/grub"
  echo 'GRUB_DISABLE_LINUX_PARTUUID=true' >>"${MOUNT}/etc/default/grub"

  # Install GRUB to MBR + post-MBR gap of the loop device.
  # arch-chroot bind-mounts /dev, so the loop device is visible inside chroot.
  arch-chroot "${MOUNT}" grub-install --target=i386-pc "${LOOPDEV}"

  # Static GRUB 2 config — cloud-image.sh will overwrite with serial console.
  cat <<'GRUBCFG' >"${MOUNT}/boot/grub/grub.cfg"
set timeout=1
set default=0

menuentry "Arch Linux" {
    linux /boot/vmlinuz-linux root=/dev/vda1 rw net.ifnames=0
    initrd /boot/initramfs-linux.img
}

menuentry "Arch Linux (fallback)" {
    linux /boot/vmlinuz-linux root=/dev/vda1 rw net.ifnames=0
    initrd /boot/initramfs-linux-fallback.img
}
GRUBCFG

  # Oneshot disk expansion: runs once on first boot, creates marker regardless
  # of success/failure so it never runs again.
  cat <<'SCRIPT' >"${MOUNT}/usr/local/bin/expand-disk"
#!/bin/bash
growpart /dev/vda 1 || true
resize2fs /dev/vda1 || true
touch /var/lib/disk-expanded
SCRIPT
  chmod 0755 "${MOUNT}/usr/local/bin/expand-disk"

  cat <<EOF >"${MOUNT}/etc/systemd/system/expand-disk.service"
[Unit]
Description=Expand root partition and filesystem (oneshot)
After=local-fs.target
ConditionPathExists=!/var/lib/disk-expanded

[Service]
Type=oneshot
RemainAfterExit=no
ExecStart=/usr/local/bin/expand-disk

[Install]
WantedBy=multi-user.target
EOF
}
