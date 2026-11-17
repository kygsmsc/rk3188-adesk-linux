#!/usr/bin/env bash
# 公共函数 / 全局路径定义。被 build.sh 及各子脚本 source。
# 所有脚本都遵守：set -Eeuo pipefail，任何一步失败立即退出并打印原因。

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 目标板标识（决定 dtb 名、mkbootimg board 名）
TARGET="${TARGET:-rk3188-adesk}"

# 内核版本（与教程一致：linux-6.12.117）
KERNEL_VERSION="${KERNEL_VERSION:-6.12.117}"

# 交叉编译器前缀（Ubuntu 包 gcc-arm-linux-gnueabihf 提供）
CROSS_COMPILE="${CROSS_COMPILE:-arm-linux-gnueabihf-}"

# 并行任务数
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

# 目录：build 放源码与中间产物，out 放最终刷机文件，.cache 放下载缓存
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
OUT_DIR="${OUT_DIR:-$ROOT/out}"
CACHE_DIR="${CACHE_DIR:-$ROOT/.cache}"

# RK3188 boot.img 的页大小（与教程中 rockchip-mkbootimg 默认值一致；
# 刷入后若卡在 loader/无输出，可改成 2048 再试一次）
BOOT_PAGESIZE="${BOOT_PAGESIZE:-16384}"

# rootfs 参数
ROOTFS_SIZE_MB="${ROOTFS_SIZE_MB:-2048}"
ROOTFS_PASSWORD="${ROOTFS_PASSWORD:-rockchip}"
ROOTFS_HOSTNAME="${ROOTFS_HOSTNAME:-rk3188-adesk}"
# 根分区设备：必须与 Parameter 的 CMDLINE root= 一致，也与 DTS 里 aliases（eMMC→mmcblk0）对应
ROOT_DEVICE="${ROOT_DEVICE:-/dev/mmcblk0p1}"
# rootfs.img 在 eMMC 上的起始扇区（= Parameter 里 mtdparts 的 rootfs @0x0000A000）
ROOTFS_OFFSET_SECTORS="${ROOTFS_OFFSET_SECTORS:-40960}"
ROOTFS_TARBALL_URL="${ROOTFS_TARBALL_URL:-https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04.5-base-armhf.tar.gz}"

mkdir -p "$BUILD_DIR" "$OUT_DIR" "$CACHE_DIR"

log()  { printf '\033[1;32m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# 需要 root 的操作（mount / chroot / mkfs / tar 解压成 root 所有）
as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo -E "$@"
    fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# 下载（带断点续传 + 重试），失败则换下一个镜像
fetch_file() {
    local dest="$1"; shift
    if [ -s "$dest" ]; then
        log "已存在缓存：$(basename "$dest")"
        return 0
    fi
    local url
    for url in "$@"; do
        log "下载 $(basename "$dest") <= $url"
        if curl -fL --retry 3 --retry-delay 5 -C - -o "$dest.part" "$url"; then
            mv "$dest.part" "$dest"
            return 0
        fi
        warn "下载失败，尝试下一个镜像：$url"
        rm -f "$dest.part"
    done
    die "所有下载地址都失败了：$(basename "$dest")"
}

kernel_series() { echo "${KERNEL_VERSION%%.*}.x"; }   # 6.12.117 -> 6.x

require_root_or_sudo() {
    if [ "$(id -u)" -ne 0 ] && ! have sudo; then
        die "该步骤需要 root（mount/chroot/mkfs），请安装 sudo 或用 root 运行"
    fi
}

# 检查 binfmt 是否已注册 arm（chroot 里跑 armhf 的 apt/dpkg 必需）
ensure_binfmt_arm() {
    if [ -e /proc/sys/fs/binfmt_misc/qemu-arm ] || [ -e /proc/sys/fs/binfmt_misc/qemu-arm-static ]; then
        return 0
    fi
    log "注册 armhf binfmt（qemu-arm-static）"
    as_root systemctl restart systemd-binfmt 2>/dev/null || true
    have update-binfmts && as_root update-binfmts --enable qemu-arm 2>/dev/null || true
    sleep 1
    [ -e /proc/sys/fs/binfmt_misc/qemu-arm ] || [ -e /proc/sys/fs/binfmt_misc/qemu-arm-static ] || \
        die "qemu-arm binfmt 未注册。请执行：sudo apt install -y qemu-user-static binfmt-support && sudo systemctl restart systemd-binfmt"
}
