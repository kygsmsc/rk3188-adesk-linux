#!/usr/bin/env bash
# 一键编译 RK3188 盒子 Linux 刷机包（boot.img + rootfs.img）
#
# 用法：
#   ./build.sh                 # 全流程：内核 -> 根文件系统 -> 打包
#   ./build.sh kernel          # 只编译内核 / dtb / 模块
#   ./build.sh rootfs          # 只做根文件系统镜像（需先有内核模块）
#   ./build.sh pack            # 只打包 boot.img
#   ./build.sh --install-deps  # 先安装编译依赖（Ubuntu/Debian）
#   ./build.sh deps            # 只检查依赖
#
# 常用环境变量（不改代码即可定制）：
#   KERNEL_VERSION=6.12.117      内核版本
#   JOBS=8                       并行编译数
#   ROOTFS_SIZE_MB=4096          根文件系统镜像大小
#   ROOTFS_PASSWORD=rockchip     root 密码
#   ROOTFS_HOSTNAME=rk3188-adesk 主机名
#   ROOT_DEVICE=/dev/mmcblk0p1   根分区设备（必须与 Parameter 的 CMDLINE 一致）
#   BOOT_PAGESIZE=16384          boot.img 页大小（引导失败可试 2048）
#
# 例：ROOTFS_SIZE_MB=4096 JOBS=8 ./build.sh all
set -Eeuo pipefail
source "$(dirname "$0")/scripts/common.sh"

DEPS_APT="build-essential gcc-arm-linux-gnueabihf libssl-dev libncurses-dev bc flex bison \
kmod rsync cpio python3 xz-utils git curl e2fsprogs dosfstools device-tree-compiler \
qemu-user-static binfmt-support parted"

DEPS_CMD="make gcc arm-linux-gnueabihf-gcc git curl tar xz mkfs.ext4 resize2fs e2fsck depmod ssh-keygen"

check_deps() {
    local missing=0
    local cmd
    for cmd in $DEPS_CMD; do
        if ! have "$cmd"; then
            warn "缺少命令：$cmd"
            missing=1
        fi
    done
    # armhf chroot 需要 qemu 静态解释器（只编译内核时可以不装）
    if ! have qemu-arm-static && [ ! -x /usr/bin/qemu-arm-static ]; then
        warn "缺少 qemu-arm-static：只编译内核没问题，做 rootfs 前请安装 qemu-user-static"
    fi
    if [ "$missing" -ne 0 ]; then
        echo
        echo "安装依赖："
        echo "  sudo apt update && sudo apt install -y $DEPS_APT"
        echo "或直接："
        echo "  ./build.sh --install-deps"
        return 1
    fi
    log "依赖检查通过"
}

install_deps() {
    log "安装编译依赖（需要 sudo）"
    as_root apt-get update
    # shellcheck disable=SC2086
    as_root apt-get install -y $DEPS_APT
    check_deps
}

banner() {
    cat <<EOF

============================================================
 RK3188 Linux 刷机包编译
 目标板     : $TARGET  (aDesk-STD-200H-s 类 RK3188 盒子)
 内核版本   : $KERNEL_VERSION
 交叉编译器 : ${CROSS_COMPILE}gcc -> $(command -v "${CROSS_COMPILE}gcc" 2>/dev/null || echo "未安装")
 并行任务   : $JOBS
 输出目录   : $OUT_DIR
 rootfs     : ${ROOTFS_SIZE_MB}MB, root 密码 ${ROOTFS_PASSWORD}, 根设备 ${ROOT_DEVICE}
 boot 页大小: ${BOOT_PAGESIZE}
============================================================

EOF
}

run_kernel() { bash "$ROOT/scripts/kernel-build.sh"; }
run_rootfs() { bash "$ROOT/scripts/rootfs-build.sh"; }
run_pack()   { bash "$ROOT/scripts/pack-build.sh"; }

ACTION="all"
case "${1:-all}" in
    all|kernel|rootfs|pack|deps) ACTION="$1" ;;
    --install-deps|-i) ACTION="install" ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "未知参数：$1（可用：all|kernel|rootfs|pack|deps|--install-deps）" ;;
esac

case "$ACTION" in
    install) install_deps; exit 0 ;;
    deps)    check_deps; exit 0 ;;
esac

check_deps
banner

START=$(date +%s)
case "$ACTION" in
    kernel) run_kernel ;;
    rootfs) run_rootfs ;;
    pack)   run_pack ;;
    all)
        run_kernel
        run_rootfs
        run_pack
        ;;
esac
log "总耗时 $(( $(date +%s) - START )) 秒"

if [ "$ACTION" = "all" ] || [ "$ACTION" = "pack" ]; then
    cat <<EOF

=================== 刷机文件 ===================
  boot.img   : $OUT_DIR/boot.img   -> 瑞芯微开发工具 地址 0x00002000
  rootfs.img : $OUT_DIR/rootfs.img -> 瑞芯微开发工具 地址 0x0000A000
  Loader     : 用原机备份的 Loader（不要用本项目的文件）
  Parameter  : 用原机的 Parameter（除非确认参数一致）
 详细步骤见：$OUT_DIR/FLASHING-GUIDE.txt
================================================
EOF
fi
