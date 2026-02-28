# arch-boxes

arch-boxes 提供面向 CloudCone `dd` 安装的 Arch Linux cloud raw 镜像构建方案。

## 镜像类型

### Cloud Raw 镜像（Superfloppy + MBR 注入 + Debian 11 兼容 ext4）
当前仓库仅保留 CloudCone / LinkCode 场景的 cloud 镜像产物链路。镜像预装 [`cloud-init`](https://cloud-init.io/)，使用 **Superfloppy + 后置 MBR 注入** 布局 + Debian 11 兼容 ext4 文件系统。更多说明可参考 [ArchWiki: Arch Linux on a VPS](https://wiki.archlinux.org/title/Arch_Linux_on_a_VPS#Official_Arch_Linux_cloud_image)。

#### 磁盘布局原理

CloudCone 宿主 GRUB 为 CentOS/RHEL 8 版本（`GRUB 2.02-81.el8`），通过 `configfile` 方式读取客户盘引导配置，且固定使用 `(hd0,msdos1)` 作为根设备：

- **Grub 2**：`set root=(hd0,msdos1); configfile /boot/grub2/grub.cfg`
- **Grub Legacy**：`set root=(hd0,msdos1); legacy_configfile /boot/grub/grub.conf`

该版本 GRUB 的 ext2 模块存在兼容性问题：当 ext4 文件系统位于标准分区偏移（通常 1 MiB）时，**目录遍历结果乱码**；但文件系统从字节 0 开始（superfloppy 模式）时可以正常读取。

本方案的解决思路：

1. **构建时**：以 superfloppy 方式创建 ext4（文件系统从字节 0 开始）
2. **构建后**：往镜像的前 512 字节注入一个最小 MBR 分区表，分区 1 的 LBA 起始 = 0，覆盖整个磁盘
3. ext4 的 "boot block"（字节 0-1023）是保留区域，超级块从字节 1024 开始，MBR 写入字节 446-511 不会破坏文件系统
4. GRUB 解析 `(hd0,msdos1)` 时，分区偏移 = 0，等效于 `(hd0)` — 文件系统可正常读取
5. VPS 的 Linux 内核检测到 MBR 后创建 `/dev/vda1`，`fstab` 和内核参数 `root=/dev/vda1` 正常工作

镜像真实文件在 `/boot/grub2/`（宿主 GRUB 读取此路径），符号链接 `/boot/grub` → `/boot/grub2`（兼容 Arch 工具），并同时提供 `grub.cfg`（GRUB 2）和 `grub.conf`（Grub Legacy）。不需要 `grub-install`（宿主提供引导器，我们只提供配置文件）。

> **注意**：构建时使用 `debian11-mke2fs.conf` 控制 `mkfs.ext4`，避免 Arch 最新 e2fsprogs 默认启用的 `metadata_csum_seed` / `orphan_file` 等 incompat 特性导致宿主 GRUB 无法识别文件系统。

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
3. 点击 **Run workflow**，填写 `version`。
4. 如需覆盖同名标签发布，可设置 `overwrite_release=true`。
5. 等待工作流执行完成。

#### 版本号与镜像大小

版本号最后一段可以指定镜像大小。格式为 `<基础版本>.<大小G>`：

- `6.18.9` — 无大小后缀，使用默认 **5G** 镜像
- `6.18.9.5G` — 构建 **5G** 镜像
- `6.18.9.18G` — 构建 **18G** 镜像
- `6.18.9.40G` — 构建 **40G** 镜像

构建脚本会自动解析版本号末尾的 `<数字>G` 后缀。如果匹配，则以该大小创建磁盘镜像；如果不匹配，则使用默认的 5G。

这种方式从构建时就确定了镜像大小，dd 写入后磁盘分区即为目标大小，**无需运行时扩容**。

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

```bash
apt-get update -qq && apt-get install -y zstd e2fsprogs util-linux
```

方式 A（`raw.zst`）：

```bash
wget -O- https://github.com/caonimagfw/arch-boxes-v2/releases/download/v6.18.9-v24.2/Arch-Linux-x86_64-cloudimg-6.18.9-v24.2.raw.zst | zstd -d | dd of=/dev/vda bs=4M status=progress conv=fsync
sync
echo b > /proc/sysrq-trigger
```

方式 B（`tar.zst`）：

```bash
wget -O- https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.tar.zst | zstd -d | tar -xO -f - --wildcards '*cloudimg*.raw' | dd of=/dev/vda bs=1M status=progress conv=fsync
sync
echo b > /proc/sysrq-trigger
```

`dd` 完成后：

1. 执行 `sync`
2. 关闭救援系统
3. 在面板切回 VPS 系统盘启动
4. 正常开机

```bash
rm -rf /etc/pacman.d/gnupg
pacman-key --init
pacman-key --populate archlinux
pacman -Syu

```



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

手动引导进入系统后，重写 `/boot/grub2/grub.cfg`：

```bash
mkdir -p /boot/grub2
cat <<'EOF' > /boot/grub2/grub.cfg
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
ln -sf grub2 /boot/grub
sync
reboot
```

### 重启黑屏 / GRUB 无法启动的修复（救援系统）

如果 `dd` 后虚拟机无法启动，可通过救援系统修复。

> **注意**：镜像使用 Superfloppy + MBR 注入布局，分区 1 起始于 LBA 0。救援系统中 `/dev/vda1` 和 `/dev/vda` 实际指向同一数据，若 `/dev/vda1` 不存在，可直接使用 `/dev/vda`。

```bash
mount /dev/vda1 /mnt  # 若不存在，改用: mount /dev/vda /mnt
mkdir -p /mnt/boot/grub2
cat <<'EOF' > /mnt/boot/grub2/grub.cfg
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
rm -rf /mnt/boot/grub
ln -sf grub2 /mnt/boot/grub
umount /mnt
sync
reboot
```

### 关于磁盘大小

镜像默认大小为 5G。如果 VPS 磁盘大于 5G，建议在构建时通过版本号后缀指定目标大小（参见上方"版本号与镜像大小"章节），这样 dd 后磁盘即为目标大小，无需额外扩容。

如果已经 dd 了默认 5G 镜像到更大的磁盘，由于镜像使用 Superfloppy + MBR 注入布局（分区 1 起始于 LBA 0），标准扩容工具可能不兼容。建议重新构建匹配目标大小的镜像。

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
