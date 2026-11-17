#!/bin/bash
# 在 armhf chroot 内执行（由 scripts/rootfs-build.sh 调用）。
# 需要的环境变量：ROOTFS_HOSTNAME / ROOTFS_PASSWORD / ROOT_DEVICE / PKG_FILE
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export TZ="${TZ:-Asia/Shanghai}"
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

echo "[chroot] apt 安装软件包"
apt-get update
# shellcheck disable=SC2046
apt-get install -y --no-install-recommends $(grep -vE '^\s*(#|$)' "$PKG_FILE")
apt-get clean

echo "[chroot] 基本系统配置"
echo "$ROOTFS_HOSTNAME" > /etc/hostname
grep -q "127.0.0.1" /etc/hosts || printf '127.0.0.1 localhost\n::1 localhost ip6-localhost ip6-loopback\n' >> /etc/hosts
grep -q "127.0.1.1" /etc/hosts || echo "127.0.1.1 $ROOTFS_HOSTNAME" >> /etc/hosts
# 固定默认 locale，避免串口登录满屏 "setlocale: LC_ALL" 警告
echo 'LANG=C.UTF-8' > /etc/default/locale

# root 密码（默认 rockchip，可在 build.sh / workflow 里改）
echo "root:$ROOTFS_PASSWORD" | chpasswd

# 串口控制台允许 root 登录（部分 login 走 pam_securetty）
grep -qx "ttyS2" /etc/securetty 2>/dev/null || echo "ttyS2" >> /etc/securetty

echo "[chroot] 开机服务（chroot 内不能 systemctl start，用软链接方式 enable）"
# 某些镜像里这些 .wants 目录是软链或已存在，用 -d 判断避免 mkdir 报 File exists
ensure_dir()  { [ -d "$1" ] || mkdir -p "$1"; }
# 强制重建软链（先删再建，重复执行也安全）
force_link()  { rm -f "$2"; ln -s "$1" "$2"; }

ensure_dir /etc/systemd/system/getty.target.wants
force_link /lib/systemd/system/serial-getty@.service /etc/systemd/system/getty.target.wants/serial-getty@ttyS2.service

ensure_dir /etc/systemd/system/multi-user.target.wants
force_link /lib/systemd/system/ssh.service /etc/systemd/system/multi-user.target.wants/ssh.service
force_link /lib/systemd/system/systemd-networkd.service /etc/systemd/system/multi-user.target.wants/systemd-networkd.service
force_link /lib/systemd/system/systemd-resolved.service /etc/systemd/system/multi-user.target.wants/systemd-resolved.service

ensure_dir /etc/systemd/system/sockets.target.wants
force_link /lib/systemd/system/systemd-networkd.socket /etc/systemd/system/sockets.target.wants/systemd-networkd.socket

ensure_dir /etc/systemd/system/sysinit.target.wants
force_link /lib/systemd/system/systemd-timesyncd.service /etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service

echo "[chroot] fstab"
cat > /etc/fstab <<EOF
# <file system>        <mount point> <type> <options>                        <dump> <pass>
$ROOT_DEVICE            /             ext4   rw,noatime,errors=remount-ro   0      1
tmpfs                  /tmp          tmpfs  mode=1777,nosuid,nodev          0      0
EOF

echo "[chroot] systemd-networkd（有线 DHCP + USB 无线网卡 DHCP）"
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/20-wired.network <<'EOF'
[Match]
Name=eth* en*

[Network]
DHCP=yes
EOF
cat > /etc/systemd/network/30-wireless.network <<'EOF'
# USB 无线网卡：默认只开 DHCP，wifi 名称/密码请用 wpa_supplicant 或 iwctl 配置
[Match]
Name=wl* wlan*

[Network]
DHCP=yes
EOF

# DNS 交给 systemd-resolved
force_link /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

echo "[chroot] SSH：允许 root + 密码登录"
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-rk3188.conf <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
EOF
grep -q 'sshd_config.d' /etc/ssh/sshd_config || echo 'Include /etc/ssh/sshd_config.d/*.conf' >> /etc/ssh/sshd_config
ssh-keygen -A

echo "[chroot] 欢迎信息"
cat > /etc/motd <<'EOF'

  RK3188 Linux (aDesk-STD-200H-s)  |  Ubuntu Base 22.04 armhf
  -------------------------------------------------------
  串口控制台 : ttyS2 115200 8N1
  登录        : root / 编译时设定的密码
  扩容根分区  : resize2fs "$(findmnt -no SOURCE /)"   (根在 loop 设备上时同样适用)
  看内核日志  : dmesg | tail  /  journalctl -b

EOF

echo "[chroot] 清理 apt 缓存"
apt-get -y autoremove --purge >/dev/null 2>&1 || true
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb /tmp/* /var/tmp/*

echo "[chroot] 完成"
