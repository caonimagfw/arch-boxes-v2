# arch-boxes

arch-boxes 提供多种虚拟机镜像构建方案。

## 镜像类型

### QCOW2 镜像
当前提供两种 QCOW2 镜像。镜像会同步到镜像站 `images` 目录，例如：<https://fastly.mirror.pkgbuild.com/images/>。

#### Basic 镜像
Basic 镜像主要用于本地场景，预置用户 `arch`（密码 `arch`），并默认启用 `sshd`。

#### Cloud 镜像
Cloud 镜像面向云环境，预装 [`cloud-init`](https://cloud-init.io/)。已验证云平台和更多说明可参考 [ArchWiki: Arch Linux on a VPS](https://wiki.archlinux.org/title/Arch_Linux_on_a_VPS#Official_Arch_Linux_cloud_image)。

## 开发与构建

### 依赖
构建前请安装以下依赖：

* arch-install-scripts
* btrfs-progs
* curl
* dosfstools
* gptfdisk
* jq
* qemu-img

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
- 默认密码：`A2vL5Y1hZ9`
- 已启用用户名/密码登录（控制台 + SSH）

### Superfloppy 结构 VPS 的 DD 操作

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

### 重启黑屏 / GRUB 无法启动的修复

如果 `dd` 后虚拟机黑屏或卡在 GRUB 阶段：

1. 进入救援系统
2. 确认镜像写入目标盘正确（`/dev/vda`）
3. 挂载根分区与 EFI 分区，重建 GRUB 配置
4. 重装 GRUB（BIOS + EFI），然后重启

参考修复命令：

```bash
mount /dev/vda3 /mnt
mount /dev/vda2 /mnt/efi
arch-chroot /mnt grub-install --target=i386-pc /dev/vda
arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/efi --removable
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
sync
reboot
```

### 引导加载器损坏：通过救援系统重装 GRUB

当引导文件损坏或丢失时，可在救援系统执行：

```bash
mount /dev/vda3 /mnt
mount /dev/vda2 /mnt/efi
arch-chroot /mnt pacman -S --noconfirm grub efibootmgr
arch-chroot /mnt grub-install --target=i386-pc /dev/vda
arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/efi --removable
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
sync
reboot
```

### 修复：启动后仅识别 2G 空间

若系统已启动但根盘仍只有约 `2G`，需要扩展第 3 分区并扩大文件系统。

先查看当前磁盘布局：

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
```

方式 1（推荐，使用 `growpart`）：

```bash
growpart /dev/vda 3
mount | grep ' on / '
btrfs filesystem resize max /
```

方式 2（无 `growpart` 时，使用 `parted`）：

```bash
parted -s /dev/vda "resizepart 3 100%"
partprobe /dev/vda
btrfs filesystem resize max /
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
