# RK3188 盒子 Linux 刷机包（在线编译）

为 **RK3188 电视盒子（aDesk-STD-200H-s 类，1GB DDR3 + eMMC + RK808 PMIC + ES8316 音频）** 一键编译：

- `boot.img` —— Linux 6.12 内核 + 本机设备树（刷到 `0x00002000`）
- `rootfs.img` —— Ubuntu Base 22.04 armhf 根文件系统（刷到 `0x0000A000`）

支持两种用法：**GitHub Actions 在线编译**（推荐，不用装交叉编译环境）、**本地 Ubuntu 一键编译**。

---

## 1. 快速开始

### 方式 A：GitHub 在线编译（不用本地环境）

1. 把本目录整个上传成一个新仓库（公开/私有都行）：

   ```bash
   cd rk3188-adesk-linux
   git init && git add -A && git commit -m "rk3188 linux build"
   git remote add origin https://github.com/<你的用户名>/<仓库名>.git
   git push -u origin main
   ```

2. 打开仓库的 **Actions** 页 → 左侧 `Build RK3188 Linux images` → 右侧 **Run workflow**。
   可改内核版本、rootfs 大小、root 密码、boot pagesize，直接点绿色按钮。

3. 约 **40~70 分钟** 后，在该次运行页面底部下载两个 artifact：
   - `rk3188-flash-images`：`boot.img`、`rootfs.img`、`parameter.txt`、`FLASHING-GUIDE.txt`
   - `rk3188-kernel-debug`：`zImage`、`rk3188-adesk.dtb`、`config-6.12.117`（排查问题用）

4. 打 tag 推送（`git tag v1.0 && git push --tags`）会自动创建 Release 并附上刷机文件。

### 方式 B：本地 Ubuntu 22.04 / 24.04 一键编译

```bash
sudo apt update
sudo ./build.sh --install-deps     # 只装依赖
./build.sh all                     # 内核 -> rootfs -> boot.img（首次 30~60 分钟）
```

分开跑（改一处不用全量重编）：

```bash
./build.sh kernel     # 只编内核 / dtb / 模块
./build.sh initramfs  # 只做 initramfs
./build.sh rootfs     # 只做 rootfs.img（会带上已编好的内核模块）
./build.sh pack       # 只把 zImage + dtb 打成 boot.img
./build.sh deps       # 只检查依赖
```

可定制项全部走环境变量，不改代码：

```bash
KERNEL_VERSION=6.12.117 \
ROOTFS_SIZE_MB=4096 \
ROOTFS_PASSWORD=你的密码 \
ROOT_DEVICE=/dev/mmcblk0p1 \
BOOT_PAGESIZE=16384 \
JOBS=8 ./build.sh all
```

产物都在 `out/`。

---

## 2. 刷机（瑞芯微开发工具 v2.58）

与工具里的分区表对应（也就是你给的截图）：

| # | 地址 | 名字 | 刷什么 |
|---|-----------|----------|----------------------|
| 1 | 0x00000000 | Loader | **原机的，不要替换** |
| 2 | 0x00000000 | Parameter | **原机的，不要随便替换** |
| 3 | 0x00002000 | boot | `boot.img` |
| 4 | 0x0000A000 | rootfs | `rootfs.img` |

**刷之前先做一件事**：在盒子原来的 Linux 系统里执行 `cat /proc/cmdline` 和 `ls /dev/mmcblk*`，
确认根分区到底是 `mmcblk0p1` 还是别的名字。本项目的 DTS 把 eMMC 固定成 `mmcblk0`（对应 `root=/dev/mmcblk0p1`）；
如果你的原机参数是 `root=/dev/mmcblk1p1`，只需要改 `dts/rk3188-adesk.dts` 里 aliases 那两行（注释里留了原写法）。

操作：只勾选第 3、4 行 → 选文件 → 盒子进 Loader 模式（按住复位孔再上电）→ 点“执行”。
详细步骤、进 Loader 的方法、回滚办法、故障对照表见 **`flash/FLASHING-GUIDE.txt`**（编译后也会复制到 `out/`）。

> **关键风险**：Loader 是引导程序、Parameter 是分区表。这两样刷错会变砖，而且再刷 boot/rootfs 也救不回来。
> 本项目**只**提供 `boot.img` 和 `rootfs.img`；`flash/parameter.txt` 仅作对照参考。
> 刷机前务必用工具“高级功能”导出原机镜像做备份。

首次开机：TTL 接 **UART2（ttyS2，115200 8N1）** 看日志；默认 `root` / 编译时设定的密码（默认 `rockchip`）；
有线网口 DHCP 自动联网；rootfs 镜像为了便于下载被缩到最小，进系统后 `resize2fs "$(findmnt -no SOURCE /)"` 用满整个分区（无分区表时根在 `/dev/loop0`，照样适用）。

---

## 3. 项目结构

```
rk3188-adesk-linux/
├── build.sh                     # 一键入口（all / kernel / rootfs / pack / deps）
├── scripts/
│   ├── common.sh                # 路径、日志、下载、sudo、binfmt 等公共函数
│   ├── kernel-build.sh          # 内核：源码 -> defconfig + 片段 -> zImage/dtb/模块
│   ├── initramfs-build.sh       # 生成 initramfs（按偏移挂载 rootfs，eMMC 无分区表时必需）
│   ├── mk-newc.py               # 不依赖 cpio 命令的 newc 打包器
│   ├── rootfs-build.sh          # rootfs：Ubuntu Base -> chroot 配置 -> ext4 镜像
│   ├── rootfs-setup.sh          # 在 armhf chroot 内部执行的配置脚本
│   └── pack-build.sh            # boot.img 打包（rockchip-mkbootimg）
├── configs/
│   ├── rk3188_adesk_defconfig   # 你提供的、来自 Armbian 5.10 的 defconfig
│   └── rk3188-adesk.fragment    # 6.12 适配片段：把本机要用的驱动改成内置
├── dts/
│   └── rk3188-adesk.dts         # 你提供的设备树（最小改动，均带注释，见第 5 节）
├── boot/
│   └── initramfs-init           # initramfs 里的 /init：按偏移 loop 挂载 rootfs.img
├── rootfs/
│   └── packages.list            # 装进根文件系统的软件包清单
├── flash/
│   ├── parameter.txt            # 分区表（仅对照，勿直接刷）
│   └── FLASHING-GUIDE.txt       # 刷机 + 排错手册
└── .github/workflows/build.yml  # GitHub Actions 在线编译
```

编译中间产物在 `build/`，下载缓存在 `.cache/`，最终文件在 `out/`（都已 gitignore）。

---

## 4. 它到底做了什么（和你的教程的对应关系）

| 教程步骤 | 本项目实现 | 说明 |
|---|---|---|
| 一.1~2 下载/解压 linux-6.12.117 | `scripts/kernel-build.sh` | 带缓存、断点续传、多镜像回退 |
| 一.3 放入 defconfig、`make 3188_defconfig` | 同名 defconfig 存入 `configs/` | 额外用 `merge_config.sh` 合并 6.12 适配片段，再 `olddefconfig` 补齐新符号 |
| 一.3 `make menuconfig` 勾驱动 | `configs/rk3188-adesk.fragment` | 把 DTS 用到的驱动固定为 `=y`，不依赖模块 |
| 一.4 `make -j16` | `make -j$JOBS zImage dtbs modules` | 同时产出 zImage、dtb、模块 |
| 一.6 合并 zImage + dtb | `scripts/pack-build.sh` | `CONFIG_ARM_APPENDED_DTB=y` 已在片段中确保 |
| 一.7 `mkbootimg --kernel kernel-dtb -o boot.img` | 同上，显式 `--pagesize` | 与教程默认 16384 一致，并检查是否超过 16MB boot 分区 |
| 二.1~5 dd + mount + tar | `scripts/rootfs-build.sh` | 不用 loop 设备：先解压成目录，最后 `mkfs.ext4 -d` 一次灌入 |
| 二.6~8 chroot、改密码、开 SSH | `scripts/rootfs-setup.sh` | 自动装 openssh、开 root 密码登录、开串口 getty、配 DHCP |
| 二.9 modules_install | 在打镜像前装进 rootfs 并 `depmod` | 顺序修正为“卸载/打包之前”，避免教程里镜像未同步的问题 |
| 二.10~11 sync、umount | 由脚本自动处理并加 `trap` 清理 | 失败也不会残留挂载点 |

和教程相比做的**必要修正**（都有注释说明原因）：

1. **设备树 aliases 修正**（`dts/rk3188-adesk.dts`）
   原写法 `mmc0 = &mmc0;`（SD 卡第一）、`mmc1 = &emmc;`，会让内部 eMMC 枚举成 `mmcblk1`；
   而 Parameter 的 `CMDLINE` 是 `root=/dev/mmcblk0p1`，内核会报 `VFS: Unable to mount root fs`。
   已改为 `mmc0 = &emmc;`（eMMC → mmcblk0）、`mmc1 = &mmc0;`（SD → mmcblk1），与 parameter.txt 对齐。
   如果你的原机 Parameter 是 `root=/dev/mmcblk1p1`，把这两行换回注释里的原写法即可。

2. **`initrd=0x62000000,0x00800000` 从 CMDLINE 去掉**
   教程用 `mkbootimg --kernel` 打包，boot.img 里没有 ramdisk；再让内核去固定地址找 initrd 只会报
   `Initramfs unpacking failed`。项目里的 `flash/parameter.txt` 已去掉这个参数。

3. **5.10 的 defconfig 直接上 6.12：符号改名是最坑的一点**
   `make olddefconfig` 只处理“已存在但不满足依赖”的符号；**符号被改名**时它不会报错，而是直接把整条驱动链丢掉，
   日志里只有一行 `warning: symbol value 'y' invalid for MFD_RK808`，很容易忽略。本机踩到的就是这一处：

   | 5.10 写法 | 6.12 实际符号 | 后果（不改的话） |
   |---|---|---|
   | `CONFIG_MFD_RK808=y` | `CONFIG_MFD_RK8XX=y`（在 `drivers/mfd/Kconfig:1271`） | RK808 的 MFD 核心不编译 |
   | `CONFIG_REGULATOR_RK808=y` | 同上，依赖 `MFD_RK8XX` | `vdd_cpu/vcc_ddr/vcc_io` 等供电拿不到 → 内核起来一半就挂 |
   | `CONFIG_COMMON_CLK_RK808=y` | 同上 | RK808 的 32.768kHz 时钟输出不工作 |
   | `CONFIG_RTC_DRV_RK808=y` | 同上（`drivers/rtc/Kconfig:409` 依赖 `MFD_RK8XX`） | RK808 自带 RTC 不注册 |

   fragment 里已改成 `MFD_RK8XX` + `MFD_RK8XX_I2C`，并且 `scripts/kernel-build.sh` 在配置完成后用 `must_cfg`
   强制校验这几项，**缺一个就直接报错停止**，不会再“编完了、刷上去才知道不启动”。

   另外 5.10 的 `CONFIG_SND_SOC_ALL_CODECS=m` 在 6.12 依赖 `COMPILE_TEST`（默认不可见），
   别指望它“把所有 codec 编进来”；本机只需要 `CONFIG_SND_SOC_ES8316=y`，fragment 已显式打开。

4. **rootfs 尺寸与 boot 分区限制**
   boot 分区在 parameter 里是 `0x00008000` 块 = 16MB，脚本会检查 `boot.img` 是否超限；
   rootfs 默认 2GB（教程里 1GB 偏紧），可在 workflow / 环境变量里改。

---

## 5. 怎么改

**加/删软件包**：编辑 `rootfs/packages.list`，一行一个，重新 `./build.sh rootfs`。
（不要加 `initramfs-tools`、`linux-image-*`，会干扰本方案。）

**改 root 密码 / 主机名 / 根分区设备**：环境变量 `ROOTFS_PASSWORD`、`ROOTFS_HOSTNAME`、`ROOT_DEVICE`。

**改设备树**：编辑 `dts/rk3188-adesk.dts`，重新 `./build.sh kernel && ./build.sh pack`。
文件里所有改动都用 `[修改 ...]` 注释标出了原始写法与原因，方便对照回退。

**改内核配置**：优先写进 `configs/rk3188-adesk.fragment`（可读、可复现、CI 也生效），
不要在本地 `menuconfig` 里改 `.config` —— 每次构建都会从 defconfig + fragment 重新生成。

**换内核版本**：`KERNEL_VERSION=6.12.20 ./build.sh all`，或 CI 里改输入参数。

---

## 6. 实机 TTL 日志诊断（2026-11 首次刷机）

首次刷入后串口日志停在最后，关键几行：

```
[    2.243826] mmcblk0: mmc0:0001 004GA1 3.69 GiB
[    2.252557] mmcblk0boot0: mmc0:0001 004GA1 2.00 MiB
[    2.355109] /dev/root: Can't open blockdev
[    2.359772] VFS: Cannot open root device "/dev/mmcblk0p1" or unknown-block(179,1): error -6
[    2.369179] Please append a correct "root=" boot option; here are the available partitions:
[    2.378595] b300         3866624 mmcblk0
[    2.386281] b320            2048 mmcblk0boot0
[    2.393944] b340            2048 mmcblk0boot1
[    2.421289] Kernel panic - not syncing: VFS: Unable to mount root fs
```

结论：**内核本身完全正常**（PMIC、eMMC、RTC、声卡 ES8316、gpio-keys 都起来了），
问题只有一个 —— 这块 eMMC 上**没有任何分区表**：日志里只有 `mmcblk0 / boot0 / boot1`，
没有 `mmcblk0p1`，所以 Parameter 里的 `root=/dev/mmcblk0p1` 找不到设备，必然 panic（error -6 = ENXIO）。

这也解释了为什么“按 0x2000 / 0xA000 裸地址刷”能刷进去却起不来：Rockchip 的 Loader 按地址找镜像，
而 **Linux 内核只认块设备分区表**（GPT/MBR），不认 Parameter 里的 mtdparts。

### 解决办法（本项目已内置，不用改 Parameter、不用动 Loader）

`boot.img` 里附带一个极小的 initramfs（armhf 静态 busybox，约 0.8MB），开机先跑 `/init`：

1. 先按常规找 `mmcblk0p1..p4`（以后你重建了分区表也能用）；
2. 找不到分区就 `losetup -o 20971520 /dev/loopX /dev/mmcblk0`，把 **0xA000 扇区（20MB）之后**的内容
   当成 ext4 直接挂载，再 `switch_root` 切到 `/sbin/init`；
3. 两条都失败时会打印明确原因并留 rescue shell，不再直接 panic。

偏移量由 `ROOTFS_OFFSET_SECTORS`（默认 40960 = 0xA000）控制，和 Parameter 里 rootfs 的 `@0x0000A000` 对齐。

### 顺带修的第二处（日志里也有）

```
rockchip_emac 10204000.ethernet: failed to retrieve phy description from device tree (-19)
rockchip_emac 10204000.ethernet: failed to probe arc emac (-19)
```
DTS 的 `&emac` 少了 `phy-mode = "rmii"`，`of_get_phy_mode()` 直接返回 -ENODEV，网口不会工作。已补上。

### 日志里看到但**不影响启动**的告警

```
vcc_ddr: failed to apply 1200000-1200000uV constraint: -EINVAL
rk808-regulator: error -EINVAL: failed to register 2 regulator
rk808-regulator: probe with driver rk808-regulator failed with error -22
```
RK808 的前两路 DCDC（vdd_arm / vdd_core）已经成功设到 1.1V，RTC（rk808-rtc、hym8563）、声卡都正常注册，
说明 PMIC 的 I2C 通信没问题；失败的是第 3 路（vcc_ddr）以及它之后的 LDO。
根因是 DTS 里 `regulators` 的写法：DCDC_REG4 的 `regulator-name` 与外部固定稳压器重名（都叫 `vcc_io`），
且给固定电压档位加了上下限约束，regulator core 在套用约束时返回 -EINVAL。
DDR 电压是 Loader 上电时设好的，所以不影响本次启动；等系统能进去以后要收拾它，
把 DCDC_REG4 改名为 `vcc_io_dcdc`、并去掉 vcc_ddr 那几行的 `regulator-min/max-microvolt` 即可。

---

## 7. 已知限制

- 主线 6.12 对 RK3188 的 **Mali GPU / VPU 硬解 / HDMI 显示**没有可用驱动；本项目把 `vop0/vop1` 保持 `disabled`，
  是**纯命令行（headless）** 系统，请通过串口或 SSH 使用。
- 板载 WiFi 不在你的 DTS 里（i2c2 上的 HDMI 芯片也标了 disabled），需要外接 USB 无线网卡；
  系统已装好 `wpasupplicant`、`iw`、`wireless-tools`。
- `parameter.txt` 里的 `MACHINE_MODEL`、`MACHINE:3066` 沿用你原机参数；不同批次盒子若分区地址不同，
  请以原机 Parameter 为准，不要照刷。
- 本地做 `rootfs.img` 需要宿主机具备 **mount / loop 设备权限**（`mkfs.ext4 -d` 失败时会回退到 loop 挂载）。
  普通的 WSL1、受限容器、部分云沙箱里跑不了这一步；GitHub Actions 的 runner 和真实 Ubuntu 机器没这个问题，
  也可以把 `./build.sh kernel` 的产物拿到有权限的机器上单独跑 `./build.sh rootfs`。
- 首次启动会比平时慢（systemd 生成 machine-id、初始化网络）；串口没有日志时先检查 TTL 是否接在 UART2。

---

## 7.1 这份工程做过哪些验证

在真实的 linux-6.12.117 源码上跑过（不是照着教程抄）：

| 项目 | 结果 |
|---|---|
| DTS 编译成 dtb | 通过，无警告；`model`/`memory@60000000`/`chosen`/aliases（mmc0=&emmc）都已核对 |
| zImage +模块 编译 | 已由 GitHub Actions（gcc 13.3）完整编出，实机也跑起来了（见第 6 节日志） |
| `rockchip-mkbootimg` | 实测 `make` 通过，`--pagesize 16384` 生成的 boot.img 头部可被 `unmkbootimg` 正常解析 |
| 6.12 配置项自检 | `CONFIG_MFD_RK8XX / REGULATOR_RK808 / COMMON_CLK_RK808 / RTC_DRV_RK808 / MMC_DW_ROCKCHIP / SERIAL_8250_DW / EMAC_ROCKCHIP / AEABI / VFP` 全部在 `.config` 里确认存在，`kernel-build.sh` 会强制校验 |
| rootfs 软件包名 | 逐个对过 `ports.ubuntu.com jammy armhf` 的 Packages 索引（main + universe），没有一个是不存在的包名 |
| rootfs 脚本逻辑 | 在 armhf 用户态（qemu + proot）里跑过解压、fstab/network/sshd 配置、软链启用服务等步骤 |
| initramfs | 本地实打包：852KB（cpio.gz），29 个条目，busybox 静态 armhf，newc 结构逐条解析通过 |
| rootfs.img 真正生成 | **只能在没有 mount 权限的沙箱里跳过**：`chroot + apt` 需要 `CAP_SYS_ADMIN`。GitHub Actions 的 runner 和真实 Ubuntu 机器上没问题 |

---

## 8. 许可证

构建脚本与本项目配置：MIT。
内核源码、`rockchip-mkbootimg`、Ubuntu Base 根文件系统遵循各自的上游许可证（GPL-2.0 / Apache-2.0 等）。
