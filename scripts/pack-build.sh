#!/usr/bin/env bash
# 打包刷机镜像：zImage + dtb -> kernel-dtb -> boot.img（Rockchip Android 头，对应教程 1.6/1.7）
# 产物：out/boot.img、out/kernel-dtb、out/parameter.txt、out/sha256sum.txt
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

MKB_DIR="$BUILD_DIR/rockchip-mkbootimg"
ZIMAGE="$OUT_DIR/zImage"
DTB="$OUT_DIR/$TARGET.dtb"
KDTB="$OUT_DIR/kernel-dtb"
BOOTIMG="$OUT_DIR/boot.img"

step "1/5 准备 mkbootimg 工具"
if [ ! -d "$MKB_DIR" ]; then
    log "克隆 rockchip-mkbootimg（Rockchip 官方 boot.img 打包工具）"
    git clone --depth 1 https://github.com/neo-technologies/rockchip-mkbootimg.git "$MKB_DIR"
fi
if [ ! -x "$MKB_DIR/mkbootimg" ]; then
    log "编译 mkbootimg（需要 libssl-dev）"
    make -C "$MKB_DIR" >/dev/null || die "mkbootimg 编译失败，请先安装 libssl-dev"
fi

step "2/5 检查内核产物"
[ -f "$ZIMAGE" ] || die "缺少 $ZIMAGE，请先执行 ./build.sh kernel"
[ -f "$DTB" ]    || die "缺少 $DTB，请先执行 ./build.sh kernel"

step "3/5 合并 zImage 与 dtb（CONFIG_ARM_APPENDED_DTB 生效的关键）"
cat "$ZIMAGE" "$DTB" > "$KDTB"
log "kernel-dtb 大小：$(du -h "$KDTB" | cut -f1)"

step "4/5 生成 boot.img（pagesize=${BOOT_PAGESIZE}）"
"$MKB_DIR/mkbootimg" \
    --kernel "$KDTB" \
    --pagesize "$BOOT_PAGESIZE" \
    --board "rk3188-adesk" \
    -o "$BOOTIMG" || die "mkbootimg 执行失败"

BOOT_BYTES=$(stat -c%s "$BOOTIMG")
log "boot.img 大小：$(du -h "$BOOTIMG" | cut -f1)（${BOOT_BYTES} 字节）"
# parameter.txt 里 boot 分区是 0x00008000 个 512B 块 = 16MB
if [ "$BOOT_BYTES" -gt $((16 * 1024 * 1024)) ]; then
    die "boot.img 超过 16MB，超过 parameter.txt 中 boot 分区大小（0x8000 块）；请精简内核或加大 boot 分区"
fi

step "5/5 输出刷机文件与校验值"
cp -f "$ROOT/flash/parameter.txt" "$OUT_DIR/parameter.txt"
cp -f "$ROOT/flash/FLASHING-GUIDE.txt" "$OUT_DIR/FLASHING-GUIDE.txt"
(
    cd "$OUT_DIR"
    for f in boot.img rootfs.img; do
        [ -f "$f" ] && sha256sum "$f"
    done
) > "$OUT_DIR/sha256sum.txt" || true
ls -lh "$OUT_DIR"
log "打包完成：$OUT_DIR"
