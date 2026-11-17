#!/usr/bin/env bash
# 编译 Linux 内核（zImage + dtb + 模块），对应教程第一部分。
# 产物：out/zImage、out/rk3188-adesk.dtb、build/modules-<ver>/lib/modules/<ver>
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

SRC_DIR="$BUILD_DIR/linux-$KERNEL_VERSION"
OBJ_DIR="$BUILD_DIR/obj-$KERNEL_VERSION"
MOD_DIR="$BUILD_DIR/modules-$KERNEL_VERSION"
DEFCONFIG="rk3188_adesk_defconfig"

step "1/7 准备内核源码 linux-$KERNEL_VERSION"
fetch_file "$CACHE_DIR/linux-$KERNEL_VERSION.tar.xz" \
    "${KERNEL_TARBALL_URL:-https://cdn.kernel.org/pub/linux/kernel/v$(kernel_series)/linux-$KERNEL_VERSION.tar.xz}" \
    "https://mirrors.tuna.tsinghua.edu.cn/kernel/v$(kernel_series)/linux-$KERNEL_VERSION.tar.xz" \
    "https://mirrors.ustc.edu.cn/kernel.org/linux/kernel/v$(kernel_series)/linux-$KERNEL_VERSION.tar.xz"

if [ ! -f "$SRC_DIR/Makefile" ]; then
    log "解压内核源码（约 1.5GB，首次较慢）"
    rm -rf "$SRC_DIR"
    tar -xf "$CACHE_DIR/linux-$KERNEL_VERSION.tar.xz" -C "$BUILD_DIR"
fi
[ -f "$SRC_DIR/Makefile" ] || die "内核源码解压失败：$SRC_DIR"
log "内核源码就绪：$SRC_DIR"

step "2/7 放入本板 defconfig 与设备树"
cp -f "$ROOT/configs/${DEFCONFIG}" "$SRC_DIR/arch/arm/configs/${DEFCONFIG}"
cp -f "$ROOT/dts/$TARGET.dts" "$SRC_DIR/arch/arm/boot/dts/rockchip/$TARGET.dts"

# 把本板 dtb 加入编译列表（重复执行也不会重复添加）
if ! grep -q "$TARGET.dtb" "$SRC_DIR/arch/arm/boot/dts/rockchip/Makefile"; then
    printf 'dtb-$(CONFIG_ARCH_ROCKCHIP) += %s.dtb\n' "$TARGET" \
        >> "$SRC_DIR/arch/arm/boot/dts/rockchip/Makefile"
fi

step "3/7 生成 .config（defconfig + 6.12 适配片段）"
mkdir -p "$OBJ_DIR"
make -C "$SRC_DIR" O="$OBJ_DIR" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" "$DEFCONFIG" >/dev/null
"$SRC_DIR/scripts/kconfig/merge_config.sh" -m -O "$OBJ_DIR" \
    "$OBJ_DIR/.config" "$ROOT/configs/rk3188-adesk.fragment" >/dev/null
make -C "$SRC_DIR" O="$OBJ_DIR" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" olddefconfig >/dev/null

# 关键项自检：配置被依赖关系悄悄关掉时，尽早报错而不是等刷机后才发现
cfg_value() {
    sed -n "s/^${1}=//p" "$OBJ_DIR/.config" | head -1
}
check_cfg() {
    local sym="$1" want="$2" got
    got="$(cfg_value "$sym")"
    if [ -z "$got" ]; then
        got="$(grep -q "^# ${sym} is not set" "$OBJ_DIR/.config" && echo "n" || echo "未定义")"
    fi
    [ "$got" = "$want" ] || warn "配置项 ${sym} 期望 ${want}，实际 ${got}"
}
must_cfg() {
    local sym="$1" want="$2" got
    got="$(cfg_value "$sym")"
    if [ "$got" != "$want" ]; then
        die "关键配置 ${sym} 期望 ${want}，实际 ${got:-未定义}（见 configs/rk3188-adesk.fragment）"
    fi
}
# 这些一旦丢了，盒子要么起不来，要么启动后没有串口/存储/供电
must_cfg CONFIG_ARM_APPENDED_DTB y
must_cfg CONFIG_MFD_RK8XX y
must_cfg CONFIG_REGULATOR_RK808 y
must_cfg CONFIG_MMC_DW_ROCKCHIP y
must_cfg CONFIG_SERIAL_8250_DW y
must_cfg CONFIG_MODULES y
# 非致命，但会直接影响外设可用性
check_cfg CONFIG_RTC_DRV_RK808 y
check_cfg CONFIG_COMMON_CLK_ROCKCHIP y
check_cfg CONFIG_I2C_RK3X y
check_cfg CONFIG_USB_DWC2 y
check_cfg CONFIG_IR_GPIO_CIR y
check_cfg CONFIG_SND_SOC_ES8316 y
# RK3188 的以太网控制器是 ARC EMAC（rockchip,rk3066-emac），不是 stmmac
check_cfg CONFIG_EMAC_ROCKCHIP y
check_cfg CONFIG_AEABI y
check_cfg CONFIG_VFP y

cp -f "$OBJ_DIR/.config" "$OUT_DIR/config-$KERNEL_VERSION"
log "内核配置：Local version=$(sed -n 's/^CONFIG_LOCALVERSION=//p' "$OBJ_DIR/.config")，版本 $(make -C "$SRC_DIR" O="$OBJ_DIR" ARCH=arm kernelrelease 2>/dev/null || echo "$KERNEL_VERSION")"

step "4/7 编译 zImage + dtb + 模块（-j$JOBS，首次 30~60 分钟）"
make -C "$SRC_DIR" O="$OBJ_DIR" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" \
    -j"$JOBS" zImage dtbs modules

step "5/7 收集内核产物"
[ -f "$OBJ_DIR/arch/arm/boot/zImage" ] || die "没有生成 zImage，请查看上面的编译错误"
[ -f "$OBJ_DIR/arch/arm/boot/dts/rockchip/$TARGET.dtb" ] || die "没有生成 $TARGET.dtb"
cp -f "$OBJ_DIR/arch/arm/boot/zImage" "$OUT_DIR/zImage"
cp -f "$OBJ_DIR/arch/arm/boot/dts/rockchip/$TARGET.dtb" "$OUT_DIR/$TARGET.dtb"
log "zImage 大小：$(du -h "$OUT_DIR/zImage" | cut -f1)；dtb 大小：$(du -h "$OUT_DIR/$TARGET.dtb" | cut -f1)"

step "6/7 安装内核模块到 staging 目录"
rm -rf "$MOD_DIR"
make -C "$SRC_DIR" O="$OBJ_DIR" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" \
    INSTALL_MOD_PATH="$MOD_DIR" INSTALL_MOD_STRIP=1 DEPMOD=/bin/true modules_install >/dev/null
[ -d "$MOD_DIR/lib/modules/$KERNEL_VERSION" ] || die "模块安装失败：$MOD_DIR/lib/modules/$KERNEL_VERSION 不存在"
log "模块数量：$(find "$MOD_DIR/lib/modules/$KERNEL_VERSION" -name '*.ko' | wc -l) 个，占用 $(du -sh "$MOD_DIR" | cut -f1)"

step "7/7 内核编译完成"
log "zImage  : $OUT_DIR/zImage"
log "设备树  : $OUT_DIR/$TARGET.dtb"
log "内核配置: $OUT_DIR/config-$KERNEL_VERSION"
log "内核模块: $MOD_DIR/lib/modules/$KERNEL_VERSION（下一步装进 rootfs）"
