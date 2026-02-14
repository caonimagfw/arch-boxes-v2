#!/bin/bash
# Build virtual machine images (cloud-image focused)

# nounset: "Treat unset variables and parameters [...] as an error when performing parameter expansion."
# errexit: "Exit immediately if [...] command exits with a non-zero status."
set -o nounset -o errexit
shopt -s extglob
readonly DEFAULT_DISK_SIZE="5G"
readonly IMAGE="image.img"
# shellcheck disable=SC2016
readonly MIRROR='https://fastly.mirror.pkgbuild.com/$repo/os/$arch'

function init() {
  readonly ORIG_PWD="${PWD}"
  readonly OUTPUT="${PWD}/output"
  local tmpdir
  tmpdir="$(mktemp --dry-run --directory --tmpdir="${PWD}/tmp")"
  readonly TMPDIR="${tmpdir}"
  mkdir -p "${OUTPUT}" "${TMPDIR}"
  if [ -n "${SUDO_UID:-}" ] && [[ -n "${SUDO_GID:-}" ]]; then
    chown "${SUDO_UID}:${SUDO_GID}" "${OUTPUT}" "${TMPDIR}"
  fi
  cd "${TMPDIR}"

  readonly MOUNT="${PWD}/mount"
  mkdir "${MOUNT}"
}

# Do some cleanup when the script exits
function cleanup() {
  # We want all the commands to run, even if one of them fails.
  set +o errexit
  if [ -n "${LOOPDEV:-}" ]; then
    losetup -d "${LOOPDEV}"
  fi
  if [ -n "${MOUNT:-}" ] && mountpoint -q "${MOUNT}"; then
    # We do not want risking deleting ex: the package cache
    umount --recursive "${MOUNT}" || exit 1
  fi
  if [ -n "${TMPDIR:-}" ]; then
    rm -rf "${TMPDIR}"
  fi
}
trap cleanup EXIT

# Create standard MBR partition table with partition 1 starting at sector 2048.
# This aligns with standard practices and CloudCone's official images.
function setup_disk() {
  truncate -s "${DEFAULT_DISK_SIZE}" "${IMAGE}"

  # Create MBR partition table:
  # Partition 1: start=2048, type=83 (Linux), bootable
  echo 'start=2048, type=83, bootable' | sfdisk "${IMAGE}"

  # Map partition 1 (offset 2048 sectors = 1048576 bytes)
  LOOPDEV=$(losetup --offset 1048576 --find --show "${IMAGE}")

  # Use explicit mkfs.ext4 features to match CloudCone's official image exactly.
  # This ensures compatibility with the host's older GRUB (2.02) which cannot read
  # modern ext4 features like 'metadata_csum' or '64bit' when using standard partitions.
  #
  # Features enabled: has_journal,ext_attr,resize_inode,dir_index,filetype,extent,flex_bg,sparse_super,large_file,huge_file,uninit_bg,dir_nlink,extra_isize
  # Features DISABLED (^): 64bit,metadata_csum,metadata_csum_seed,orphan_file
  mkfs.ext4 -F -O "^64bit,^metadata_csum,^metadata_csum_seed,^orphan_file,has_journal,ext_attr,resize_inode,dir_index,filetype,extent,flex_bg,sparse_super,large_file,huge_file,uninit_bg,dir_nlink,extra_isize" "${LOOPDEV}"
  mount "${LOOPDEV}" "${MOUNT}"
}

# Install Arch Linux to the filesystem (bootstrap)
function bootstrap() {
  cat <<EOF >pacman.conf
[options]
Architecture = auto
SigLevel = DatabaseOptional

[core]
Include = mirrorlist

[extra]
Include = mirrorlist
EOF
  echo "Server = ${MIRROR}" >mirrorlist

  # We use the hosts package cache
  pacstrap -c -C pacman.conf -K -M "${MOUNT}" base linux grub openssh sudo e2fsprogs qemu-guest-agent
  # Workaround for https://gitlab.archlinux.org/archlinux/arch-install-scripts/-/issues/56
  gpgconf --homedir "${MOUNT}/etc/pacman.d/gnupg" --kill gpg-agent
  cp mirrorlist "${MOUNT}/etc/pacman.d/"
}

# Cleanup the image and trim it
function image_cleanup() {
  # Remove pacman key ring for re-initialization
  rm -rf "${MOUNT}/etc/pacman.d/gnupg/"

  # The mkinitcpio autodetect hook removes modules not needed by the
  # running system from the initramfs. This make the image non-bootable
  # on some systems as initramfs lacks the relevant kernel modules.
  # Ex: Some systems need the virtio-scsi kernel module and not the
  # "autodetected" virtio-blk kernel module for disk access.
  #
  # So for the initial install we skip the autodetct hook.
  arch-chroot "${MOUNT}" /usr/bin/mkinitcpio -p linux -- -S autodetect

  sync -f "${MOUNT}/etc/os-release"
  fstrim --verbose "${MOUNT}"
}

# Mount image helper (loop device + mount) — partition 1 offset
function mount_image() {
  # Mount partition 1 (offset 2048 sectors = 1048576 bytes)
  LOOPDEV=$(losetup --offset 1048576 --find --show "${1:-${IMAGE}}")
  mount "${LOOPDEV}" "${MOUNT}"
  # Setup bind mount to package cache
  mount --bind "/var/cache/pacman/pkg" "${MOUNT}/var/cache/pacman/pkg"
}

# Unmount image helper (umount + detach loop device)
function unmount_image() {
  umount --recursive "${MOUNT}"
  losetup -d "${LOOPDEV}"
  LOOPDEV=""
}


# Compute SHA256, adjust owner to $SUDO_UID:$SUDO_UID and move to output/
function mv_to_output() {
  local artifact tar_zst
  local -a artifacts

  artifacts=("${1}")
  sha256sum "${1}" >"${1}.SHA256"
  artifacts+=("${1}.SHA256")

  if [ -f "${1}.zst" ]; then
    sha256sum "${1}.zst" >"${1}.zst.SHA256"
    artifacts+=("${1}.zst" "${1}.zst.SHA256")
  fi

  tar_zst="${1%.raw}.tar.zst"
  if [ -f "${tar_zst}" ]; then
    sha256sum "${tar_zst}" >"${tar_zst}.SHA256"
    artifacts+=("${tar_zst}" "${tar_zst}.SHA256")
  fi

  if [ -n "${SUDO_UID:-}" ]; then
    chown "${SUDO_UID}:${SUDO_GID}" "${artifacts[@]}"
  fi
  for artifact in "${artifacts[@]}"; do
    mv "${artifact}" "${OUTPUT}/"
  done
}

# Helper function: create a new image from the "base" image
# ${1} - final file
# ${2} - pre
# ${3} - post
function create_image() {
  local tmp_image
  tmp_image="$(basename "$(mktemp -u)")"
  cp -a "${IMAGE}" "${tmp_image}"
  if [ -n "${DISK_SIZE}" ]; then
    truncate -s "${DISK_SIZE}" "${tmp_image}"
  fi
  mount_image "${tmp_image}"
  if [ -n "${DISK_SIZE}" ]; then
    resize2fs "${LOOPDEV}"
  fi

  if [ 0 -lt "${#PACKAGES[@]}" ]; then
    arch-chroot "${MOUNT}" /usr/bin/pacman -S --noconfirm "${PACKAGES[@]}"
  fi
  if [ 0 -lt "${#SERVICES[@]}" ]; then
    arch-chroot "${MOUNT}" /usr/bin/systemctl enable "${SERVICES[@]}"
  fi
  "${2}"
  image_cleanup
  unmount_image
  "${3}" "${tmp_image}" "${1}"
  mv_to_output "${1}"
}

# ${1} - Optional build version. If not set, will generate a default based on date.
function main() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "root is required"
    exit 1
  fi

  if ! command -v tar >/dev/null 2>&1 || ! command -v zstd >/dev/null 2>&1; then
    echo "Required tools missing: tar and zstd must be installed on the build host."
    exit 1
  fi

  init

  setup_disk
  bootstrap
  # shellcheck source=images/base.sh
  source "${ORIG_PWD}/images/base.sh"
  pre
  unmount_image

  local build_version
  if [ -z "${1:-}" ]; then
    build_version="$(date +%Y%m%d).0"
    echo "WARNING: BUILD_VERSION wasn't set!"
    echo "Falling back to $build_version"
  else
    build_version="${1}"
  fi

  local image_filter image_count
  image_filter="${IMAGE_FILTER:-cloud-image.sh}"
  image_count=0
  for image in "${ORIG_PWD}/images/"!(base).sh; do
    if [[ ! "$(basename "${image}")" == ${image_filter} ]]; then
      continue
    fi
    # shellcheck source=/dev/null
    source "${image}"
    create_image "${IMAGE_NAME}" pre post
    image_count=$((image_count + 1))
  done

  if [ "${image_count}" -eq 0 ]; then
    echo "No image matched IMAGE_FILTER='${image_filter}'"
    exit 1
  fi
}
main "$@"
