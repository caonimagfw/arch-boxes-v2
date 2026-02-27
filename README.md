# arch-boxes

arch-boxes 提供面向 `dd` 安装的 Arch Linux cloud raw 镜像构建方案。

## 镜像类型

### Cloud Raw 镜像（标准 MBR 自引导 + ext4）
当前仓库保留 cloud 镜像产物链路。镜像预装 [`cloud-init`](https://cloud-init.io/)，使用 **标准 BIOS/MBR 自引导** 布局。更多说明可参考 [ArchWiki: Arch Linux on a VPS](https://wiki.archlinux.org/title/Arch_Linux_on_a_VPS#Official_Arch_Linux_cloud_image)。

#### 磁盘布局

镜像采用标准 BIOS/MBR 引导方式，`grub-install` 在构建时写入引导代码：

| 区域 | 偏移 | 内容 |
|---|---|---|
| Sector 0 | 字节 0-511 | MBR：GRUB boot.img (446B) + 分区表 (64B) + 55AA 签名 (2B) |
| Sectors 1-2047 | 512B - 1 MiB | GRUB core.img（post-MBR gap） |
| Sector 2048+ | 1 MiB 起 | Partition 1：ext4 根分区（含 2G swapfile） |

引导链：BIOS → MBR boot.img → core.img → `/boot/grub/grub.cfg` → kernel

镜像默认大小 5G，首次启动时 `expand-disk.service`（oneshot）自动执行 `growpart` + `resize2fs` 扩展分区和文件系统至磁盘实际大小。该服务无论成功与否只运行一次，后续开机不再执行。

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

## Cloud Raw 发布（GitHub Actions）

仓库内置了 GitHub Actions 工作流，构建 cloud 镜像并发布两种压缩格式。

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
- `Arch-Linux-x86_64-cloudimg-<version>.raw.gz`（用于 leitbogioro 等 dd 脚本）
- `Arch-Linux-x86_64-cloudimg-<version>.raw.gz.SHA256`

工作流会创建 `v<version>` 标签的 GitHub Release，并上传以上文件。

镜像默认登录策略：

- 默认用户：`root`
- 默认密码：`Passw0rd`
- 已启用用户名/密码登录（控制台 + SSH）
- 已启用开机自启：`sshd`、`systemd-networkd`、`systemd-resolved`

### DD 操作（救援系统）

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
wget -O- https://github.com/OWNER/REPO/releases/download/vX.Y.Z/Arch-Linux-x86_64-cloudimg-X.Y.Z.raw.zst | zstd -d | dd of=/dev/vda bs=1M status=progress conv=fsync
```

方式 B（`tar.zst`）：

```bash
wget -O- https://github.com/OWNER/REPO/releases/download/vX.Y.Z/Arch-Linux-x86_64-cloudimg-X.Y.Z.tar.zst | zstd -d | tar -xO -f - --wildcards '*cloudimg*.raw' | dd of=/dev/vda bs=1M status=progress conv=fsync
```

`dd` 完成后（`conv=fsync` 已确保数据落盘）：

1. 关闭救援系统
2. 在面板切回 VPS 系统盘启动
3. 正常开机（首次启动自动扩容分区）

### DD 一键脚本：自动记录并恢复网络

在**当前在线系统**（或救援系统）中执行以下脚本，会自动完成：记录当前 IP/网关 → 预生成配置到 tmpfs → 复制关键工具到 tmpfs → dd 写盘 → 通过 losetup+debugfs 写入网络配置 → 重启。

> **使用前**：将 `DD_URL` 替换为实际镜像地址。脚本假设磁盘为 `/dev/vda`、网络接口为 `eth0`（镜像内核使用 `net.ifnames=0`）。
>
> **在线 dd 原理**：dd 覆盖磁盘后，所有磁盘上的文件（包括共享库）均已丢失。脚本在 dd 前将 `debugfs`、`losetup` 及其依赖库复制到 `/run`（tmpfs / 内存），确保 dd 后仍可正常执行。dd 后通过 `losetup --offset` 创建指向新分区偏移的干净 loop 设备，再用 `debugfs -w` 绕过 VFS 直接向 ext4 写入配置。

```bash
#!/bin/bash
set -euo pipefail

# 【关键修复】将整个脚本包在 main 函数中
# 这样 bash 会在执行前将整个函数体读入内存。
# 防止 dd 覆盖磁盘后，bash 从被覆盖的磁盘中读出新镜像的二进制乱码当成脚本执行，从而引发 SQLite syntax error 等离奇崩溃。
main() {
  # 安装依赖；当前系统已有则跳过
  for pkg in zstd e2fsprogs util-linux; do
    if ! dpkg -s "$pkg" &>/dev/null; then
      apt-get update -qq && apt-get install -y zstd e2fsprogs util-linux
      break
    fi
  done

  DD_URL="https://github.com/caonimagfw/arch-boxes-v2/releases/download/v6.18.9-MBR-V2/Arch-Linux-x86_64-cloudimg-6.18.9-MBR-V2.raw.zst"
  DISK="/dev/vda"
  # 新镜像分区 1 从 sector 2048 开始 (1 MiB = 1048576 字节)
  PART_OFFSET=1048576

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

  # 2b. 复制 debugfs + losetup 及其所有动态链接库到 tmpfs
  copy_bin_to_tmpfs() {
    local bin="$1"
    cp "$bin" "$WORK/bin/$(basename "$bin")"
    ldd "$bin" 2>/dev/null | awk '{print $1, $3}' | while read -r lib path; do
      local target="${path:-$lib}"
      [[ -n "$target" && -f "$target" ]] && cp -nL "$target" "$WORK/lib/" 2>/dev/null || true
    done
    chmod +x "$WORK/bin/$(basename "$bin")"
  }

  DEBUGFS_BIN="$(command -v debugfs || command -v /sbin/debugfs || command -v /usr/sbin/debugfs || true)"
  if [[ -z "$DEBUGFS_BIN" ]]; then echo "ERROR: debugfs not found"; exit 1; fi
  copy_bin_to_tmpfs "$DEBUGFS_BIN"

  LOSETUP_BIN="$(command -v losetup || command -v /sbin/losetup || command -v /usr/sbin/losetup || true)"
  if [[ -z "$LOSETUP_BIN" ]]; then echo "ERROR: losetup not found"; exit 1; fi
  copy_bin_to_tmpfs "$LOSETUP_BIN"

  echo "Config + tools saved to tmpfs ($WORK)"

  # ---- 3. DD 前释放内存并冻结旧文件系统 ----
  swapoff -a 2>/dev/null || true
  systemctl stop cron rsyslog snapd unattended-upgrades 2>/dev/null || true
  
  echo "Syncing data to disk..."
  sync

  # 确保 sysrq 开启，防止部分系统（如 Debian 12）默认禁用导致无响应
  echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true

  # 【关键】SysRq-U 强制所有挂载点刷写脏页并 remount read-only。
  # 必须轮询等待变 ro，否则 dd 覆盖磁盘后，旧系统遗留的脏页回写会破坏新镜像。
  echo u > /proc/sysrq-trigger
  echo "Waiting for filesystems to become read-only..."
  for i in {1..30}; do
    if ! grep -E '^/dev/.* rw,' /proc/mounts >/dev/null 2>&1; then
      echo "All physical filesystems are read-only."
      break
    fi
    sleep 1
    if [[ $i -eq 30 ]]; then
      echo "ERROR: Timeout waiting for ro. Aborting to prevent corruption."
      exit 1
    fi
  done

  # 丢弃所有底层块设备的页缓存，防止 sysrq-s 时写回幽灵脏数据
  blockdev --flushbufs "${DISK}" 2>/dev/null || true
  echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

  echo "Starting dd..."

  # ---- 4. DD 写盘 ----
  umount -R ${DISK}* 2>/dev/null || true
  set +o pipefail
  wget -O- "$DD_URL" | zstd -d | dd of="$DISK" bs=4M iflag=fullblock oflag=direct status=progress conv=fsync
  DD_EXIT=${PIPESTATUS[2]}
  set -o pipefail
  if [[ $DD_EXIT -ne 0 ]]; then echo "ERROR: dd failed (exit $DD_EXIT)"; exit 1; fi

  # ---- 5. 用 tmpfs 中的工具写入配置 ----
  # 新镜像的 ext4 从 sector 2048 (1 MiB) 开始，不能直接 debugfs /dev/vda。
  # 也不能用 /dev/vda1 — 内核分区缓存可能是旧系统的，存在脏数据风险。
  # 解法：losetup --offset 创建干净的 loop 设备，指向新分区的精确偏移。

  shopt -s nullglob
  LD_SO_ARR=( "$WORK"/lib/ld-linux-*.so* )
  shopt -u nullglob
  if [[ ${#LD_SO_ARR[@]} -eq 0 ]]; then echo "ERROR: ld-linux not found in tmpfs"; exit 1; fi
  LD_SO="${LD_SO_ARR[0]}"

  set +e

  # 创建指向新分区偏移的干净 loop 设备
  LOOP_NEW=$("$LD_SO" --library-path "$WORK/lib" "$WORK/bin/losetup" --find --show --offset "$PART_OFFSET" "$DISK" 2>/dev/null)

  if [[ -n "$LOOP_NEW" ]]; then
    "$LD_SO" --library-path "$WORK/lib" "$WORK/bin/debugfs" -w -R \
      "write $WORK/20-wired.network /etc/systemd/network/20-wired.network" "$LOOP_NEW" 2>/dev/null || true
    "$LD_SO" --library-path "$WORK/lib" "$WORK/bin/debugfs" -w -R \
      "write $WORK/99-disable-network-config.cfg /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg" "$LOOP_NEW" 2>/dev/null || true
    "$LD_SO" --library-path "$WORK/lib" "$WORK/bin/losetup" -d "$LOOP_NEW" 2>/dev/null || true
  fi

  echo "Network config written. Rebooting via SysRq S-U-B..."

  # 【重启策略】纯内核态 SysRq S-U-B 安全重启序列。
  #
  # dd 覆盖磁盘后，所有用户态命令（sync、reboot -f 等）都会因底层 ext4
  # 结构已被新镜像取代而 Segfault / "Structure needs cleaning"。
  # 因此只能使用 echo > /proc/sysrq-trigger（内核内联处理）和
  # Bash 内置的 read -t（不触碰磁盘）来完成重启。
  #
  # 在 KVM/QEMU 虚拟化环境中，dd conv=fsync 虽然在 Guest 层面完成了
  # FLUSH，但宿主机（Host）的存储后端（如网络磁盘、ceph、LVM）可能
  # 仍有数据在 Host 页缓存中未落盘。SysRq-S 触发内核级 Emergency Sync，
  # 向 virtio 驱动发送额外的 FLUSH/FUA 指令；长等待（共 10 秒）给
  # 宿主机存储后端充足的物理落盘时间。

  # S = Emergency Sync：刷写所有内核脏缓冲区，向虚拟磁盘发送 FLUSH
  echo s > /proc/sysrq-trigger
  read -t 5 < /dev/udp/127.0.0.1/65535 2>/dev/null || true

  # U = Emergency Remount R/O：触发额外的设备级刷盘信号
  echo u > /proc/sysrq-trigger
  read -t 5 < /dev/udp/127.0.0.1/65535 2>/dev/null || true

  # B = 立即硬重启
  echo b > /proc/sysrq-trigger
}

main "$@"
```

说明：

- **强制全量读入内存**：整个脚本被包裹在 `main` 函数中。Bash 遇到函数声明时，会把整个函数体一次性读入内存（解析为 AST）再执行。这能避免 dd 期间/之后，Bash 采用流式读取时从被覆盖的物理扇区读出新镜像的二进制文件，从而引发"当作 shell 执行二进制乱码"（如 SQLite syntax error）的致命崩溃。
- **`swapoff -a`**：swap 分区/文件在被 dd 覆盖的磁盘上，不关闭则内核 swap-in 时读到垃圾数据会 kernel panic，swap-out 则破坏新镜像
- **独立 tmpfs + exec**：`/run` 默认挂载 `noexec`，无法执行复制过去的二进制。脚本在 `/run/dd-work` 上挂载独立 tmpfs 并带 `exec` 权限，确保 debugfs 和 losetup 可正常执行
- **额外复制 losetup 到 tmpfs**：新镜像的 ext4 从 sector 2048（1 MiB）开始，不在字节 0。dd 后不能直接 `debugfs /dev/vda`（找不到 ext4 超级块），也不能用 `/dev/vda1`（内核缓存了旧系统的分区映射，存在脏数据风险）。解法：用 `losetup --offset 1048576 /dev/vda` 创建一个全新的 loop 设备，精确指向新分区偏移，无缓存污染
- **强制使用 tmpfs 中的动态链接器**：即使设置了 `LD_LIBRARY_PATH`，执行 `/run/dd-work/bin/debugfs` 时仍会默认调用 elf 头中硬编码的 `/lib64/ld-linux-x86-64.so.2`。因为 `/lib64` 位于已被覆盖的磁盘上，这会导致执行失败。解决方案是直接调用 tmpfs 中的动态链接器（`$LD_SO`），并用 `--library-path` 参数去加载并执行二进制
- **`iflag=fullblock`**：`oflag=direct` 要求写入长度对齐到磁盘扇区（512B），管道 `read()` 可能返回短读导致非对齐写入失败；`iflag=fullblock` 强制 dd 凑满完整块再写
- **`oflag=direct`**：dd 写出走 Direct I/O 绕过页缓存，减少对内存中其他缓存页（如 bash 自身）的冲击
- **`set +o pipefail` + `PIPESTATUS[2]`**：dd 覆盖磁盘后 `wget` 清理阶段可能因共享库丢失而 segfault（退出码 139），`pipefail` 会把这个无害错误当作管道失败导致脚本中断。临时关闭 `pipefail`，只检查 `dd` 的退出码（管道第 3 个命令）
- **dd 前释放内存**：停止非关键服务 + 释放页缓存，为 dd 管道（wget + zstd）腾出最大可用内存
- **SysRq-U（remount read-only）+ 轮询等待**：dd 前强制所有挂载点刷写脏页并 remount read-only。由于 SysRq-U 是异步执行的，脚本会轮询 `/proc/mounts` 阻塞等待，直到所有的文件系统真正变为 `ro` 后才允许执行 `dd`。这一步确保旧系统不再产生脏页。
- **`blockdev --flushbufs`**：清空底层块设备的幽灵缓存，彻底切断旧系统与磁盘的联系
- **dd 后不执行 `drop_caches`**：dd 覆盖磁盘后，旧系统的共享库/二进制缓存是唯一让后续 debugfs（通过 tmpfs 中的 ld.so）能运行的保障。如果清掉这些缓存，内核在加载任何外部命令时都会尝试从已被覆盖的磁盘上读取，导致 `Segmentation fault` 或 `Structure needs cleaning`
- **`debugfs -w`**：绕过 VFS mount 直接操作 ext4 结构，不受内核旧根挂载的 exclusive claim 限制
- **SysRq S-U-B 安全重启序列**：dd 后整个用户态已是"行尸走肉"——磁盘上的二进制已被新镜像取代，任何用户态命令（`sync`、`reboot -f`）都会 Segfault。因此只能使用纯内核态的 SysRq 触发器来重启。`S`（Emergency Sync）向 virtio 虚拟磁盘控制器发送 FLUSH 指令，通知宿主机（Host）将页缓存中的数据持久化到物理存储；`U`（Emergency Remount R/O）触发额外的设备级刷盘信号；中间共等待 10 秒给宿主机存储后端（可能是网络磁盘、Ceph、LVM）充足的物理落盘时间；最后 `B` 立即硬重启。所有等待都使用 Bash 内置的 `read -t`（不触碰磁盘）
- 镜像已预建 `/etc/systemd/network/` 和 `/etc/cloud/cloud.cfg.d/` 目录，`debugfs write` 可直接写入
- 如果 VPS 的 IP 不在当前网卡上（例如需要手动指定），可直接在脚本顶部覆盖 `IP4`、`GW4` 变量
- **兜底方案**：如果脚本自动重启后仍然出现 fsck 失败，可从 VPS 控制面板（如 CloudCone）执行 **Power Off → Power On**（物理级电源循环），强制宿主机重置虚拟磁盘状态。如果仍不行，进入救援模式执行 `e2fsck -yf /dev/vda1` 修复文件系统后重启

### DD 操作（leitbogioro 一键重装脚本）

使用 [leitbogioro/Tools](https://github.com/leitbogioro/Tools) 的 `InstallNET.sh` 脚本 dd 自定义镜像。该脚本先将一个小型 Debian 12 内核加载到内存，重启后从内存中的系统执行 dd，磁盘处于空闲状态，不存在 live dd 的页缓存冲突问题。

> **前提**：需要 VNC/控制台访问能力（dd 后需从控制台配置网络）。镜像必须使用 `.raw.gz` 格式（脚本不支持 zstd）。

**1. SSH 登录当前系统，下载脚本：**

```bash
apt update -y && apt install wget -y
wget --no-check-certificate -qO InstallNET.sh 'https://raw.githubusercontent.com/leitbogioro/Tools/master/Linux_reinstall/InstallNET.sh' && chmod a+x InstallNET.sh
```

**2. 执行 dd（静态网络）：**

```bash
bash InstallNET.sh -dd 'https://github.com/OWNER/REPO/releases/download/vX.Y.Z/Arch-Linux-x86_64-cloudimg-X.Y.Z.raw.gz' \
  --network "static" \
  --ip-addr 'IPv4地址' \
  --ip-mask '掩码前缀(如24)' \
  --ip-gate 'IPv4网关' \
  --ip-dns '1.1.1.1'
```

如有 IPv6，追加参数：

```bash
  --ip6-addr 'IPv6地址' \
  --ip6-mask 'IPv6前缀长度' \
  --ip6-gate 'IPv6网关'
```

> `--network "static"` 和 `--ip-*` 参数用于中间系统（内存中的 Debian 12）联网下载镜像，不会注入到目标镜像中。

**3. 等待自动重启完成 dd**

脚本自动修改 GRUB 并重启，从内存中的 Debian 12 下载并 dd 镜像，全程无需干预。

**4. 从 VNC 配置网络**

dd 完成后系统自动重启进入新镜像。从 VPS 控制面板打开 VNC，使用默认凭据登录（`root` / `Passw0rd`），手动写入网络配置：

```bash
cat > /etc/systemd/network/20-wired.network <<EOF
[Match]
Name=eth0

[Network]
Address=你的IPv4/掩码
Gateway=你的网关
DNS=1.1.1.1
DNS=8.8.8.8
EOF
```

如有 IPv6：

```bash
cat >> /etc/systemd/network/20-wired.network <<EOF

Address=你的IPv6/前缀长度
Gateway=你的IPv6网关
DNS=2606:4700:4700::1111
EOF
```

禁用 cloud-init 网络覆盖并重启网络：

```bash
echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
systemctl restart systemd-networkd
```

验证连通后即可切回 SSH。

### 手动引导：通过 GRUB 控制台启动（按 C）

如果 `dd` 后 GRUB 菜单无法自动启动，可在 GRUB 菜单界面按 **`c`** 进入命令行，逐条输入以下命令手动引导：

```
insmod part_msdos
insmod ext2
set root=(hd0,msdos1)
linux /boot/vmlinuz-linux root=/dev/vda1 rw net.ifnames=0 console=tty0
initrd /boot/initramfs-linux.img
boot
```

### 进入系统后：重建引导配置

手动引导进入系统后，重新生成 `/boot/grub/grub.cfg`：

```bash
grub-mkconfig -o /boot/grub/grub.cfg
sync
reboot
```

或手写静态配置：

```bash
cat <<'EOF' > /boot/grub/grub.cfg
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
EOF
sync
reboot
```

### 重启黑屏 / GRUB 无法启动的修复（救援系统）

如果 `dd` 后虚拟机无法启动，可通过救援系统修复。

```bash
mount /dev/vda1 /mnt
# 重新安装 GRUB 到 MBR
grub-install --target=i386-pc --boot-directory=/mnt/boot /dev/vda
# 重新生成配置
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
umount /mnt
sync
reboot
```

如果救援系统没有 `grub-install`，可手写静态配置：

```bash
mount /dev/vda1 /mnt
cat <<'EOF' > /mnt/boot/grub/grub.cfg
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
EOF
umount /mnt
sync
reboot
```

### 首次启动自动扩容

镜像内置 `expand-disk.service`（oneshot），首次开机自动执行 `growpart /dev/vda 1` + `resize2fs /dev/vda1` 扩展根分区到磁盘实际大小。无论成功与否，服务只运行一次，后续开机不再执行。

如需手动扩容：

```bash
growpart /dev/vda 1
resize2fs /dev/vda1
```

已知限制与排障：

- 工作流运行于 `ubuntu-latest`，并使用特权 Docker 容器。若预检失败，可稍后重试或改用自托管 Linux Runner。
- `version` 会映射为发布标签 `v<version>`。除非 `overwrite_release=true`，否则请保持版本唯一。
- 发布产物为 `raw.zst`、`tar.zst` 和 `raw.gz`，每个产物都启用了体积阈值保护，超限会提前失败。
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
