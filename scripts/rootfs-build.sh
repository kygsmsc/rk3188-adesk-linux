#!/usr/bin/env bash
# 制作 Ubuntu Base 22.04 armhf 根文件系统镜像，对应教程第二部分。
# 与教程的差异：不 dd 一块空盘再 mount（CI 环境里 loop 设备经常不可用），
# 而是先把 rootfs 解压成目录 -> chroot 配置 -> 最后 mkfs.ext4 -d 一次性灌进镜像。
# 产物：out/rootfs.img（ext4，标签 rootfs）
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

ROOT_DEVICE="${ROOT_DEVICE:-/dev/mmcblk0p1}"
ROOTFS_DIR="$BUILD_DIR/rootfs-root"
MOD_DIR="$BUILD_DIR/modules-$KERNEL_VERSION"
IMG="$OUT_DIR/rootfs.img"
UBUNTU_BASE_TGZ="$CACHE_DIR/$(basename "$ROOTFS_TARBALL_URL")"

require_root_or_sudo

step "1/8 下载 Ubuntu Base 22.04 armhf 根文件系统"
fetch_file "$UBUNTU_BASE_TGZ" "$ROOTFS_TARBALL_URL"
[ -s "$UBUNTU_BASE_TGZ" ] || die "根文件系统包为空：$UBUNTU_BASE_TGZ"

step "2/8 解压到工作目录（root 所有）"
ensure_binfmt_arm
as_root rm -rf "$ROOTFS_DIR"
as_root mkdir -p "$ROOTFS_DIR"
as_root tar -xzf "$UBUNTU_BASE_TGZ" -C "$ROOTFS_DIR" --numeric-owner -p
[ -x "$ROOTFS_DIR/bin/bash" ] || die "解压后找不到 /bin/bash，根文件系统包可能损坏"
log "根文件系统已解压：$(as_root du -sh "$ROOTFS_DIR" | cut -f1)"

step "3/8 写入 apt 源 / DNS / 非交互配置"
as_root tee "$ROOTFS_DIR/etc/apt/sources.list" >/dev/null <<'EOF'
# Ubuntu 22.04 (jammy) armhf —— armhf 属于 ports 仓库
deb http://ports.ubuntu.com/ubuntu-ports jammy main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports jammy-updates main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports jammy-backports main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports jammy-security main restricted universe multiverse
EOF
as_root mkdir -p "$ROOTFS_DIR/etc/apt/apt.conf.d"
as_root tee "$ROOTFS_DIR/etc/apt/apt.conf.d/99-build.conf" >/dev/null <<'EOF'
Acquire::ForceIPv4 "true";
Acquire::Retries "3";
Acquire::Languages "none";
APT::Sandbox::User "root";
EOF
as_root tee "$ROOTFS_DIR/etc/resolv.conf" >/dev/null <<'EOF'
nameserver 223.5.5.5
nameserver 1.1.1.1
EOF

step "4/8 挂载伪文件系统并 chroot 安装软件包"
# 绑定 /dev /proc /sys，退出时自动卸载
MOUNTS=()
# 必须倒序卸载（dev/pts 挂在 dev 里面），否则 /dev 卸不掉，mkfs 会把宿主机的 /dev 灌进镜像
cleanup_mounts() {
    local i
    for (( i=${#MOUNTS[@]}-1; i>=0; i-- )); do
        as_root umount "$ROOTFS_DIR/${MOUNTS[i]}" 2>/dev/null || true
    done
    MOUNTS=()
    if grep -q "$ROOTFS_DIR" /proc/mounts 2>/dev/null; then
        warn "仍有挂载点未卸载："
        grep "$ROOTFS_DIR" /proc/mounts >&2 || true
        die "请先手工 umount $ROOTFS_DIR 下的挂载点再重跑"
    fi
}
trap cleanup_mounts EXIT INT TERM
bind_mount() {
    as_root mount --bind "/$1" "$ROOTFS_DIR/$1"
    MOUNTS+=("$1")
}
bind_mount dev
as_root mkdir -p "$ROOTFS_DIR/dev/pts"
bind_mount dev/pts
bind_mount proc
bind_mount sys

as_root cp -f "$ROOT/rootfs/packages.list" "$ROOTFS_DIR/tmp/packages.list"
as_root cp -f "$ROOT/scripts/rootfs-setup.sh" "$ROOTFS_DIR/tmp/rootfs-setup.sh"
as_root chmod +x "$ROOTFS_DIR/tmp/rootfs-setup.sh"

# chroot 里 apt 装包时不要让服务真去启动（很多服务在没有内核的 chroot 里必失败）
printf '#!/bin/sh\nexit 101\n' > "$BUILD_DIR/policy-rc.d"
as_root cp -f "$BUILD_DIR/policy-rc.d" "$ROOTFS_DIR/usr/sbin/policy-rc.d"
as_root chmod +x "$ROOTFS_DIR/usr/sbin/policy-rc.d"

as_root chroot "$ROOTFS_DIR" /usr/bin/env -i \
    HOME=/root \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    TERM=xterm \
    LANG=C.UTF-8 \
    TZ=Asia/Shanghai \
    ROOTFS_HOSTNAME="$ROOTFS_HOSTNAME" \
    ROOTFS_PASSWORD="$ROOTFS_PASSWORD" \
    ROOT_DEVICE="$ROOT_DEVICE" \
    PKG_FILE=/tmp/packages.list \
    /bin/bash /tmp/rootfs-setup.sh

as_root rm -f "$ROOTFS_DIR/tmp/rootfs-setup.sh" "$ROOTFS_DIR/tmp/packages.list" \
             "$ROOTFS_DIR/usr/sbin/policy-rc.d"
cleanup_mounts
trap - EXIT INT TERM

step "5/8 安装内核模块到 rootfs"
if [ -d "$MOD_DIR/lib/modules/$KERNEL_VERSION" ]; then
    as_root mkdir -p "$ROOTFS_DIR/lib/modules"
    as_root cp -a "$MOD_DIR/lib/modules/." "$ROOTFS_DIR/lib/modules/"
    # modules_install 生成的 build/source 是编译机的绝对路径软链，刷到盒子上没意义
    as_root rm -rf "$ROOTFS_DIR/lib/modules/$KERNEL_VERSION/build" \
                 "$ROOTFS_DIR/lib/modules/$KERNEL_VERSION/source"
    as_root depmod -b "$ROOTFS_DIR" "$KERNEL_VERSION" 2>/dev/null || \
        warn "depmod 未成功（不影响开机，只是模块不会自动按依赖加载）"
    log "内核模块已安装：$(as_root find "$ROOTFS_DIR/lib/modules/$KERNEL_VERSION" -name '*.ko' | wc -l) 个"
else
    warn "没有找到 $MOD_DIR/lib/modules/$KERNEL_VERSION —— 本次 rootfs 不含内核模块"
    warn "如果内核里把 USB/网卡等驱动编成了 <m>，这些硬件开机后不会工作，请先执行 ./build.sh kernel"
fi

step "6/8 统计内容体积并生成 ext4 镜像（${ROOTFS_SIZE_MB}MB）"
USED_MB=$(as_root du -sm "$ROOTFS_DIR" | cut -f1)
log "rootfs 目录占用 ${USED_MB}MB"
if [ "$USED_MB" -gt $((ROOTFS_SIZE_MB - 200)) ]; then
    die "rootfs 内容 ${USED_MB}MB，超过镜像 ${ROOTFS_SIZE_MB}MB 的安全余量；请调大 ROOTFS_SIZE_MB 后重跑"
fi

as_root rm -f "$IMG"
as_root truncate -s "${ROOTFS_SIZE_MB}M" "$IMG"

# 首选 mkfs.ext4 -d（直接把目录灌进镜像，不需要 loop 设备）。
# 某些文件系统（overlayfs / 无 xattr 支持的容器）会因“无法读取 xattr”失败，此时退回 loop 挂载方式。
if ! as_root mkfs.ext4 -q -F -L rootfs -m 0 -b 4096 -d "$ROOTFS_DIR" "$IMG" 2>"$BUILD_DIR/mkfs-ext4.log"; then
    warn "mkfs.ext4 -d 失败，改用 loop 挂载方式（原因见 $BUILD_DIR/mkfs-ext4.log）"
    tail -5 "$BUILD_DIR/mkfs-ext4.log" >&2 || true
    rm -f "$IMG"
    as_root truncate -s "${ROOTFS_SIZE_MB}M" "$IMG"
    as_root mkfs.ext4 -q -F -L rootfs -m 0 -b 4096 "$IMG"
    MNT="$BUILD_DIR/.rootfs-mnt"
    as_root rm -rf "$MNT"; as_root mkdir -p "$MNT"
    as_root mount -o loop "$IMG" "$MNT" || die "loop 挂载失败：请在有 mount 权限的宿主机上运行（受限容器里不行）"
    trap 'as_root umount "$MNT" 2>/dev/null || true' EXIT INT TERM
    as_root cp -a "$ROOTFS_DIR/." "$MNT/"
    as_root sync
    as_root umount "$MNT"
    trap - EXIT INT TERM
    as_root rmdir "$MNT" 2>/dev/null || true
fi

step "7/8 校验镜像"
as_root e2fsck -f -y -q "$IMG" >/dev/null || true
as_root resize2fs -M "$IMG" >/dev/null 2>&1 || true   # 顺带缩到最小，便于下载
log "rootfs.img 实际大小：$(du -h "$IMG" | cut -f1)（分区更大也没关系，进系统后 resize2fs 扩容）"

step "8/8 完成"
log "根文件系统镜像：$IMG"
log "默认登录：root / ${ROOTFS_PASSWORD}    根设备：${ROOT_DEVICE}"
