#!/usr/bin/env bash
# 生成 initramfs（armhf 静态 busybox），对应“eMMC 没有分区表”这种情况。
#
# 为什么需要它：
#   本机 eMMC 是裸的（无 GPT/MBR），Parameter 里的 root=/dev/mmcblk0p1 根本不存在，
#   内核会 panic：VFS: Cannot open root device "/dev/mmcblk0p1" ... error -6。
#   把 rootfs.img 刷在 0x0000A000 之后，用 loop 设备按偏移挂载即可，
#   这样既不用改 Parameter，也不用冒险重写 eMMC 的分区表。
#
# 产物：out/initramfs.cpio.gz（由 scripts/pack-build.sh 作为 --ramdisk 打进 boot.img）
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

BUSYBOX_DEB="$CACHE_DIR/busybox-static_1.30.1-7ubuntu3_armhf.deb"
BUSYBOX_URL="${BUSYBOX_URL:-https://ports.ubuntu.com/ubuntu-ports/pool/main/b/busybox/busybox-static_1.30.1-7ubuntu3_armhf.deb}"
IRFS_DIR="$BUILD_DIR/initramfs-root"
OUT_FILE="$OUT_DIR/initramfs.cpio.gz"

# rootfs.img 在 eMMC 上的起始扇区（与 Parameter 的 mtdparts 里 rootfs 的 @0x0000A000 对应）
ROOTFS_OFFSET_SECTORS="${ROOTFS_OFFSET_SECTORS:-40960}"      # 40960 = 0xA000 = 20MB

step "1/4 下载静态 busybox（armhf）"
fetch_file "$BUSYBOX_DEB" "$BUSYBOX_URL"
[ -s "$BUSYBOX_DEB" ] || die "busybox-static 下载失败：$BUSYBOX_DEB"

step "2/4 组装 initramfs 目录"
rm -rf "$IRFS_DIR"
mkdir -p "$IRFS_DIR"/{bin,dev,proc,sys,tmp,newroot}
dpkg-deb -x "$BUSYBOX_DEB" "$BUILD_DIR/busybox-extract" 2>/dev/null || true
SRC_BB="$BUILD_DIR/busybox-extract/bin/busybox"
[ -f "$SRC_BB" ] || die "解包后找不到 bin/busybox：$BUSYBOX_DEB"
cp -f "$SRC_BB" "$IRFS_DIR/bin/busybox"
chmod 755 "$IRFS_DIR/bin/busybox"

# 只准备真正用得到的 applet，体积和出错面都小
for a in sh mount umount losetup switch_root mkdir mknod ls cat echo sleep \
         dmesg mountpoint poweroff reboot grep cut sed awk; do
    ln -sf busybox "$IRFS_DIR/bin/$a"
done
ln -sf sh "$IRFS_DIR/bin/ash"

sed "s/@@OFFSET_SECTORS@@/${ROOTFS_OFFSET_SECTORS}/" "$ROOT/boot/initramfs-init" > "$IRFS_DIR/init"
chmod 755 "$IRFS_DIR/init"
[ -x "$IRFS_DIR/bin/busybox" ] || die "busybox 不可执行（下载到了错误的架构？）"

step "3/4 打包成 cpio.gz"
# 优先用 cpio 命令；没有 cpio 的环境（精简容器）用自带的 python 生成 newc，效果一样
if have cpio; then
    ( cd "$IRFS_DIR" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 ) > "$OUT_FILE"
else
    log "环境里没有 cpio，改用 scripts/mk-newc.py 生成 newc"
    python3 "$ROOT/scripts/mk-newc.py" "$IRFS_DIR" "$BUILD_DIR/initramfs.cpio"
    gzip -9 -c "$BUILD_DIR/initramfs.cpio" > "$OUT_FILE"
fi
# busybox 本身约 1MB，压缩后不该小于 200KB —— 太小说明打包是空的
[ "$(stat -c%s "$OUT_FILE")" -gt 200000 ] || die "initramfs 打包异常（$(stat -c%s "$OUT_FILE") 字节），检查 busybox 是否解包成功"
log "initramfs：$OUT_FILE（$(du -h "$OUT_FILE" | cut -f1)），rootfs 偏移 ${ROOTFS_OFFSET_SECTORS} 扇区"

step "4/4 完成"
log "下一步：./build.sh kernel（若还没编）→ ./build.sh pack 生成带 ramdisk 的 boot.img"
