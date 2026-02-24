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

镜像使用 `/boot/grub2/` 作为真实目录（匹配宿主 GRUB 的 `configfile /boot/grub2/grub.cfg` 路径），`/boot/grub` → `/boot/grub2` 为符号链接（兼容 Arch `grub` 包默认路径）。同时提供 `grub.cfg`（GRUB 2）和 `grub.conf`（Grub Legacy）。不需要 `grub-install`（宿主提供引导器，我们只提供配置文件）。

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
```

方式 B（`tar.zst`）：

```bash
wget -O- https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.tar.zst | zstd -d | tar -xO -f - --wildcards '*cloudimg*.raw' | dd of=/dev/vda bs=1M status=progress conv=fsync
```

`dd` 完成后（`conv=fsync` 已确保数据落盘）：

1. 关闭救援系统
3. 在面板切回 VPS 系统盘启动
4. 正常开机

### DD 一键脚本：自动记录并恢复网络

在**当前在线系统**（或救援系统）中执行以下脚本，会自动完成：记录当前 IP/网关 → 预生成配置到 tmpfs → 复制关键工具到 tmpfs → dd 写盘 → debugfs 写入网络配置 → 重启。

> **使用前**：将 `DD_URL` 替换为实际镜像地址。脚本假设磁盘为 `/dev/vda`、网络接口为 `eth0`（镜像内核使用 `net.ifnames=0`）。
>
> **在线 dd 原理**：dd 覆盖磁盘后，所有磁盘上的文件（包括共享库）均已丢失。脚本在 dd 前将 `debugfs` 及其依赖库复制到 `/run`（tmpfs / 内存），确保 dd 后仍可正常执行。使用 `debugfs -w` 绕过 VFS 直接向 ext4 写入配置（内核旧根挂载仍持有块设备，mount 不可用）。

```bash
#!/bin/bash
set -euo pipefail

# 【关键修复】将整个脚本包在 main 函数中
# 这样 bash 会在执行前将整个函数体读入内存。
# 防止 dd 覆盖磁盘后，bash 从被覆盖的磁盘中读出新镜像的二进制乱码当成脚本执行，从而引发 SQLite syntax error 等离奇崩溃。
main() {
  # 安装依赖；当前系统已有则跳过
  for pkg in zstd e2fsprogs; do
    if ! dpkg -s "$pkg" &>/dev/null; then
      apt-get update -qq && apt-get install -y zstd e2fsprogs
      break
    fi
  done

  DD_URL="https://github.com/OWNER/REPO/releases/download/vX.Y.Z/Arch-Linux-x86_64-cloudimg-X.Y.Z.raw.zst"
  DISK="/dev/vda"
  PART="${DISK}1"

  # ---- 1. 记录当前网络 ----
  DEV=$(ip -4 route show default | grep -oP 'dev \K\w+' | head -n 1 || true)
  IP4=$(ip -4 addr show "${DEV:-}" 2>/dev/null | grep -oP 'inet \K[\d.]+/\d+' | grep -v '127\.0\.0\.' | head -n 1 || true)
  GW4=$(ip -4 route show default | grep -oP 'via \K[\d.]+' | head -n 1 || true)

  DEV6=$(ip -6 route show default | grep -oP 'dev \K\w+' | head -n 1 || true)
  IP6=$(ip -6 addr show "${DEV6:-$DEV}" scope global 2>/dev/null | grep -oP 'inet6 \K[0-9a-f:]+/\d+' | head -n 1 || true)
  GW6=$(ip -6 route show default | grep -oP 'via \K[0-9a-f:]+' | head -n 1 || true)

  echo "IPv4: addr=$IP4 gw=$GW4"
  echo "IPv6: addr=${IP6:-none} gw=${GW6:-none}"

  # ---- 2. 在 tmpfs 上准备配置文件和关键工具 ----
  WORK="/run/dd-work"
  mkdir -p "$WORK"
  mount -t tmpfs -o size=64m,exec tmpfs "$WORK"
  mkdir -p "$WORK/bin" "$WORK/lib"

  # 2a. 预生成网络配置
  cat > "$WORK/20-wired.network" <<EOF
[Match]
Name=eth0

[Network]
Address=${IP4}
Gateway=${GW4}
DNS=1.1.1.1
DNS=8.8.8.8
EOF

  if [[ -n "${IP6:-}" ]]; then
  cat >> "$WORK/20-wired.network" <<EOF

Address=${IP6}
Gateway=${GW6}
DNS=2606:4700:4700::1111
DNS=2001:4860:4860::8888
EOF
  fi

  echo 'network: {config: disabled}' > "$WORK/99-disable-network-config.cfg"

  # 2b. 复制 debugfs 及其所有动态链接库到 tmpfs
  DEBUGFS_BIN="$(command -v debugfs || command -v /sbin/debugfs || command -v /usr/sbin/debugfs || true)"
  if [[ -z "$DEBUGFS_BIN" ]]; then echo "ERROR: debugfs not found"; exit 1; fi
  cp "$DEBUGFS_BIN" "$WORK/bin/debugfs"
  ldd "$DEBUGFS_BIN" 2>/dev/null | awk '{print $1, $3}' | while read -r lib path; do
    # 两种情况：
    # 1. libfoo.so => /lib/libfoo.so (path=/lib/libfoo.so)
    # 2. /lib/ld-linux.so.2 (lib=/lib/ld-linux.so.2, path="")
    target="${path:-$lib}"
    [[ -n "$target" && -f "$target" ]] && cp -nL "$target" "$WORK/lib/" 2>/dev/null || true
  done
  chmod +x "$WORK/bin/debugfs"

  echo "Config + tools saved to tmpfs ($WORK)"

  # ---- 3. DD 前释放内存 ----
  swapoff -a 2>/dev/null || true
  systemctl stop cron rsyslog snapd unattended-upgrades 2>/dev/null || true
  echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

  echo "Starting dd..."

  # ---- 4. DD 写盘 ----
  umount -R ${DISK}* 2>/dev/null || true
  set +o pipefail
  wget -O- "$DD_URL" | zstd -d | dd of="$DISK" bs=4M iflag=fullblock oflag=direct status=progress conv=fsync
  DD_EXIT=${PIPESTATUS[2]}
  set -o pipefail
  if [[ $DD_EXIT -ne 0 ]]; then echo "ERROR: dd failed (exit $DD_EXIT)"; exit 1; fi

  # ---- 5. 清除内核页缓存，确保 debugfs 读到新文件系统 ----
  echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

  # ---- 6. 用 tmpfs 中的 debugfs 写入配置 ----
  # 【关键修复】必须直接操作 $DISK (/dev/vda)，绝对不能用 /dev/vda1！
  # 因为旧系统仍挂载在 /dev/vda1，其内核 buffer cache 中充满旧系统的 ext4 元数据。
  # debugfs 读取 /dev/vda1 会得到新旧混合的脏数据，导致 "inode is not a directory" 报错。
  # 且新镜像的 ext4 文件系统正是从字节 0 开始（Superfloppy），直接操作 /dev/vda 完全正确。

  # 使用 Bash 内部 globbing 查找 ld-linux，避免调用 external `find` 和 `head` 导致崩溃
  shopt -s nullglob
  LD_SO_ARR=( "$WORK"/lib/ld-linux-*.so* )
  shopt -u nullglob
  if [[ ${#LD_SO_ARR[@]} -eq 0 ]]; then echo "ERROR: ld-linux not found in tmpfs"; exit 1; fi
  LD_SO="${LD_SO_ARR[0]}"

  set +e  # 关闭 set -e，防止 debugfs 因意外的非零退出码导致脚本中断

  "$LD_SO" --library-path "$WORK/lib" "$WORK/bin/debugfs" -w -R \
    "write $WORK/20-wired.network /etc/systemd/network/20-wired.network" "$DISK" 2>/dev/null || true
  "$LD_SO" --library-path "$WORK/lib" "$WORK/bin/debugfs" -w -R \
    "write $WORK/99-disable-network-config.cfg /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg" "$DISK" 2>/dev/null || true

  echo "Network config written. Rebooting..."
  echo s > /proc/sysrq-trigger

  # 使用 Bash 内部的方式实现 sleep 2 秒（向不存在的 udp 端口 read 超时），避免调用 external `sleep` 导致崩溃
  read -t 2 < /dev/udp/127.0.0.1/65535 2>/dev/null || true

  echo b > /proc/sysrq-trigger
}

main "$@"
```

说明：

- **强制全量读入内存**：整个脚本被包裹在 `main` 函数中。Bash 遇到函数声明时，会把整个函数体一次性读入内存（解析为 AST）再执行。这能避免 dd 期间/之后，Bash 采用流式读取时从被覆盖的物理扇区读出新镜像的二进制文件，从而引发“当作 shell 执行二进制乱码”（如 SQLite syntax error）的致命崩溃。
- **`swapoff -a`**：swap 分区/文件在被 dd 覆盖的磁盘上，不关闭则内核 swap-in 时读到垃圾数据会 kernel panic，swap-out 则破坏新镜像
- **独立 tmpfs + exec**：`/run` 默认挂载 `noexec`，无法执行复制过去的二进制。脚本在 `/run/dd-work` 上挂载独立 tmpfs 并带 `exec` 权限，确保 debugfs 可正常执行
- **强制使用 tmpfs 中的动态链接器**：即使设置了 `LD_LIBRARY_PATH`，执行 `/run/dd-work/bin/debugfs` 时仍会默认调用 elf 头中硬编码的 `/lib64/ld-linux-x86-64.so.2`。因为 `/lib64` 位于已被覆盖的磁盘上，这会导致执行失败。解决方案是直接调用 tmpfs 中的动态链接器（`$LD_SO`），并用 `--library-path` 参数去加载并执行 debugfs
- **`iflag=fullblock`**：`oflag=direct` 要求写入长度对齐到磁盘扇区（512B），管道 `read()` 可能返回短读导致非对齐写入失败；`iflag=fullblock` 强制 dd 凑满完整块再写
- **`oflag=direct`**：dd 写出走 Direct I/O 绕过页缓存，减少对内存中其他缓存页（如 bash 自身）的冲击
- **`set +o pipefail` + `PIPESTATUS[2]`**：dd 覆盖磁盘后 `wget` 清理阶段可能因共享库丢失而 segfault（退出码 139），`pipefail` 会把这个无害错误当作管道失败导致脚本中断。临时关闭 `pipefail`，只检查 `dd` 的退出码（管道第 3 个命令）
- **dd 前释放内存**：停止非关键服务 + 释放页缓存，为 dd 管道（wget + zstd）腾出最大可用内存
- **`echo s` + `echo b` > `/proc/sysrq-trigger`**：SysRq-S 触发 emergency sync 确保 debugfs 写入的数据落盘，`sleep 2` 等待完成后 SysRq-B 立即重启，全程不依赖任何用户态二进制
- **`debugfs -w`**：绕过 VFS mount 直接操作 ext4 结构，不受内核旧根挂载的 exclusive claim 限制
- 镜像已预建 `/etc/systemd/network/` 和 `/etc/cloud/cloud.cfg.d/` 目录，`debugfs write` 可直接写入
- 如果 VPS 的 IP 不在当前网卡上（例如需要手动指定），可直接在脚本顶部覆盖 `IP4`、`GW4` 变量

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
ln -sfn grub2 /boot/grub
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
ln -sfn grub2 /mnt/boot/grub
umount /mnt
sync
reboot
```

### 修复：启动后仅识别 5G 空间

若系统已启动但根盘仍只有约 `5G`（镜像原始大小），需扩展分区和文件系统。

由于镜像使用 Superfloppy + MBR 注入布局（分区 1 起始于 LBA 0），扩展方式如下：

方式 1（推荐，使用 `growpart`）：

```bash
growpart /dev/vda 1
resize2fs /dev/vda1
```

方式 2（无 `growpart` 时，使用 `sfdisk` 重写分区表）：

```bash
# 删除旧分区并重建覆盖全盘的分区（数据不变，只改分区表）
echo ',,L,*' | sfdisk --force /dev/vda
partprobe /dev/vda
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
