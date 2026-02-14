# arch-boxes

arch-boxes 提供面向 CloudCone `dd` 安装的 Arch Linux cloud raw 镜像构建方案。

## 镜像类型

### Cloud Raw 镜像（标准 MBR 分区 + Debian 11 兼容 ext4）
当前仓库仅保留 CloudCone / LinkCode 场景的 cloud 镜像产物链路。镜像预装 [`cloud-init`](https://cloud-init.io/)，使用 **标准 MBR 分区布局**（分区 1 起始于 2048 扇区） + Debian 11 兼容 ext4 文件系统。更多说明可参考 [ArchWiki: Arch Linux on a VPS](https://wiki.archlinux.org/title/Arch_Linux_on_a_VPS#Official_Arch_Linux_cloud_image)。

本方案采用 **标准 MBR 分区方案**（分区 1 从 2048 扇区开始），并深度定制 ext4 文件系统特性以兼容 CloudCone 宿主 GRUB。

#### 磁盘布局原理

CloudCone 宿主 GRUB 版本为 `GRUB 2.02-81.el8`。经过深入分析官方镜像，该版本 GRUB 虽然支持读取标准偏移的分区，但不支持现代 ext4 的 `64bit` (64位块寻址) 和 `metadata_csum` (元数据校验) 特性。

因此，构建时使用 `debian11-mke2fs.conf` 配置文件（通过 `MKE2FS_CONFIG` 环境变量完全覆盖构建主机的默认配置），精确控制 ext4 特性：

- **禁用**: `64bit`, `metadata_csum`, `metadata_csum_seed`, `orphan_file`
- **启用**: `has_journal`, `ext_attr`, `resize_inode`, `dir_index`, `extent`, `flex_bg`, `sparse_super`, `large_file`, `huge_file`, `uninit_bg`, `dir_nlink`, `extra_isize`

这样既保持了标准的分区表结构（方便 `sfdisk`/`growpart` 扩容），又完美兼容宿主引导器。

镜像使用符号链接 `/boot/grub2` → `/boot/grub` 兼容 RHEL 路径约定，并同时提供 `grub.cfg`（GRUB 2）和 `grub.conf`（Grub Legacy）。不需要 `grub-install`（宿主提供引导器，我们只提供配置文件）。

> **注意**：构建时使用 `debian11-mke2fs.conf` 控制 `mkfs.ext4`（通过 `MKE2FS_CONFIG` 环境变量），完全隔离构建主机的 e2fsprogs 默认配置。这确保了无论 Arch Linux 的 e2fsprogs 版本多新，格式化出的 ext4 始终只包含我们指定的特性集。

## 开发与构建

### 依赖
构建前请安装以下依赖：

* arch-install-scripts
* e2fsprogs
* util-linux
* zstd

### 本地构建
以 `root` 身份执行：

    ./build.sh

## CloudCone Raw 发布（GitHub Actions）

仓库内置了面向 CloudCone `dd` 安装的 GitHub Actions 工作流。
该工作流会构建 cloud 镜像，并同时发布两种压缩格式，适配不同 `dd` 用法。

工作流文件：

`/.github/workflows/build-cloudcone-raw.yml`

使用方式（Actions）：

1. 进入 GitHub 的 **Actions** 页面。
2. 选择 **Build CloudCone Arch Raw**。
3. 点击 **Run workflow**，填写 `version`（默认 `6.18.7`）。
4. 如需覆盖同名标签发布，可设置 `overwrite_release=true`。
5. 等待工作流执行完成。

发布产物：

- `Arch-Linux-x86_64-cloudimg-<version>.raw.zst`
- `Arch-Linux-x86_64-cloudimg-<version>.raw.zst.SHA256`
- `Arch-Linux-x86_64-cloudimg-<version>.tar.zst`
- `Arch-Linux-x86_64-cloudimg-<version>.tar.zst.SHA256`

工作流会创建 `v<version>` 标签的 GitHub Release，并上传以上文件。

镜像默认登录策略：

- 默认用户：`root`
- 默认密码：`Passw0rd`
- 已启用用户名/密码登录（控制台 + SSH）
- 已启用开机自启：`sshd`、`systemd-networkd`、`systemd-resolved`

### CloudCone VPS 的 DD 操作

在救援系统中，先确认目标磁盘（通常是 `/dev/vda`）：

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
```

如果目标磁盘分区已挂载，先卸载：

```bash
umount -R /dev/vda* 2>/dev/null || true
```

以下两种方式二选一。

方式 A（`raw.zst`）：

```bash
wget -O- https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.raw.zst | zstd -d | dd of=/dev/vda bs=1M status=progress conv=fsync
sync
```

方式 B（`tar.zst`）：

```bash
wget -O- https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.tar.zst | zstd -d | tar -xO -f - --wildcards '*cloudimg*.raw' | dd of=/dev/vda bs=1M status=progress conv=fsync
sync
```

`dd` 完成后：

1. 执行 `sync`
2. 关闭救援系统
3. 在面板切回 VPS 系统盘启动
4. 正常开机

### 手动引导：通过 GRUB 2 控制台启动（按 C）

如果 `dd` 后宿主 GRUB 菜单无法自动启动，可在 GRUB 2 菜单界面按 **`c`** 进入命令行，逐条输入以下命令手动引导：

```
insmod part_msdos
insmod ext2
set root=(hd0,msdos1)
linux /boot/vmlinuz-linux root=/dev/vda1 rw net.ifnames=0 console=tty0 console=ttyS0,115200
initrd /boot/initramfs-linux.img
boot
```

### 进入系统后：重建引导配置

手动引导进入系统后，重写 `/boot/grub/grub.cfg`：

```bash
cat <<'EOF' > /boot/grub/grub.cfg
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
EOF
ln -sf grub /boot/grub2
sync
reboot
```

### 重启黑屏 / GRUB 无法启动的修复（救援系统）

如果 `dd` 后虚拟机无法启动，可通过救援系统修复。

```bash
mount /dev/vda1 /mnt
mkdir -p /mnt/boot/grub
cat <<'EOF' > /mnt/boot/grub/grub.cfg
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
EOF
ln -sf grub /mnt/boot/grub2
umount /mnt
sync
reboot
```

### 自动扩容

镜像已内置自动扩容脚本，首次启动时会自动扩展根分区以利用全部磁盘空间。

若自动扩容失败（例如识别到根盘仍只有约 `5G`），可手动执行以下命令修复。

由于镜像使用 **标准 MBR 分区**（分区 1 起始于 2048 扇区），可直接使用标准工具扩容。

**手动扩容命令：**

```bash
# 1. 扩容分区
growpart /dev/vda 1

# 2. 在线扩容文件系统
resize2fs /dev/vda1
```

已知限制与排障：

- 工作流运行于 `ubuntu-latest`，并使用特权 Docker 容器。若预检失败，可稍后重试或改用自托管 Linux Runner。
- `version` 会映射为发布标签 `v<version>`。除非 `overwrite_release=true`，否则请保持版本唯一。
- 发布产物为 `raw.zst` 与 `tar.zst`，每个产物都启用了体积阈值保护，超限会提前失败。
- 若发布已存在且未开启覆盖，请更换版本号或启用覆盖后重试。

# 发布签名

所有 Release 均由 CI 使用以下公钥签名：
```
-----BEGIN PGP PUBLIC KEY BLOCK-----

mDMEYpOJrBYJKwYBBAHaRw8BAQdAcSZilBvR58s6aD2qgsDE7WpvHQR2R5exQhNQ
yuILsTq0JWFyY2gtYm94ZXMgPGFyY2gtYm94ZXNAYXJjaGxpbnV4Lm9yZz6IkAQT
FggAOBYhBBuaFphKToy0SHEtKuC3i/QybG+PBQJik4msAhsBBQsJCAcCBhUKCQgL
AgQWAgMBAh4BAheAAAoJEOC3i/QybG+P81YA/A7HUftMGpzlJrPYBFPqW0nFIh7m
sIZ5yXxh7cTgqtJ7AQDFKSrulrsDa6hsqmEC11PWhv1VN6i9wfRvb1FwQPF6D7gz
BGKTiecWCSsGAQQB2kcPAQEHQBzLxT2+CwumKUtfi9UEXMMx/oGgpjsgp2ehYPBM
N8ejiPUEGBYIACYWIQQbmhaYSk6MtEhxLSrgt4v0MmxvjwUCYpOJ5wIbAgUJCWYB
gACBCRDgt4v0Mmxvj3YgBBkWCAAdFiEEZW5MWsHMO4blOdl+NDY1poWakXQFAmKT
iecACgkQNDY1poWakXTwaQEAwymt4PgXltHUH8GVUB6Xu7Gb5o6LwV9fNQJc1CMl
7CABAJw0We0w1q78cJ8uWiomE1MHdRxsuqbuqtsCn2Dn6/0Cj+4A/Apcqm7uzFam
pA5u9yvz1VJBWZY1PRBICBFSkuRtacUCAQC7YNurPPoWDyjiJPrf0Vzaz8UtKp0q
BSF/a3EoocLnCA==
=APeC
-----END PGP PUBLIC KEY BLOCK-----
```
