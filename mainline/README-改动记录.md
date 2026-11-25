# MT6755 M5 Note 主线内核 — 改动记录

> 工作目录：`laptop:/mnt/shared/mt6755-mainline/work/`
> 时间：2026-11-26
> 状态：dts 语法验证通过（dtc 生成 7.0 KB dtb），config 已改，未编译

---

## 目录结构

```
work/
├── dts/
│   ├── mt6755-k50v1.dts       # 参考原版（只读）
│   └── mt6755-m5note.dts      # ⭐ 你的板级 dts（已改）
├── config/
│   ├── config-6.12.115        # 参考原版（只读）
│   └── m5note.config          # ⭐ 你的 config（已改）
├── patches/                   # yao140514 的驱动补丁（复制待用）
│   ├── pinctrl-mt6755.c
│   ├── pinctrl-mtk-mt6755.h
│   ├── i2c-mt65xx.c
│   ├── phy-mtk-tphy.c
│   ├── mtu3_plat.c            # 不用（mtu3→musb）
│   └── psci.c
├── scripts/bootimg.py         # MTK boot.img 打包
└── docs/{bringup,consys}.md   # 踩坑记录
```

---

## 一、dts 改动（mt6755-m5note.dts）

从参考 `mt6755-k50v1.dts`（475 行）改为 421 行：

| 项 | 原值 (k50v1) | 你的值 (M5 Note) |
|---|---|---|
| model | `ALPS k50v1_64_bsp (MT6750)` | `Meizu M5 Note (MT6755)` |
| compatible | `alps,k50v1-64-bsp` | `meizu,m5note` |
| bootargs | `console=ttyS0,921600n8 ... fbcon=map:0` | `console=ttyMT0,921600n1 earlycon ...` |
| 内存 | `0x20000000` (512 MB) | `0xC0000000` (3 GB) |
| framebuffer | simplefb 节点 | **删除**（你不要显示） |
| touchscreen@5d | 有 | **删除** |
| bus-width | 8 | **4**（实测） |

### 保留的关键节点（LK 必需，不能删）

```
reserved-memory {}           # LK 启动时写 atf-reserved/ram_console
odm/accdet/touch/... 占位     # odmdtbo overlay 通过 __symbols__ 找这些 label
```

### USB 大改（mtu3 → musb）

| 项 | 原值 (mtu3) | 新值 (musb) |
|---|---|---|
| 节点 | `usb@11271000` | **`usb@11270000`**（实测地址） |
| compatible | `mediatek,mtu3` | `mediatek,mt6755-musb`, `mediatek,mtk-musb` |
| reg | `<0x11271000 0x3000>, <0x11280700 0x100>` | `<0x11270000 0x1000>` |
| 中断 | `<0 72 8>` | `<0 72 8>` + `interrupt-names="mc"` |
| clocks | 无 | main/mcu/univpll（fixed-clock 48 MHz） |
| dr_mode | peripheral | **otg** |
| PHY | `mt8173-u3phy` | `mediatek,mt6755-tphy`, `mediatek,generic-tphy-v1` |
| u3p-dis-msk | `<1>` | 删除（mtu3 专用） |

**依据**：主线 `drivers/usb/musb/mediatek.c` 的 `mtk_musb_match[] = { "mediatek,mtk-musb" }`，
参考 `arch/arm64/boot/dts/mediatek/mt8516.dtsi` 的 usb0 节点（同为 GIC_SPI 72）。

### 验证

```sh
cpp -nostdinc -I /tmp/kinc ... -x assembler-with-cpp dts/mt6755-m5note.dts -o /tmp/test.dts
dtc -I dts -O dtb -o /tmp/test.dtb /tmp/test.dts   # ✅ 通过，7.0 KB
```

---

## 二、config 改动（m5note.config）

| 项 | 原值 | 新值 |
|---|---|---|
| `CONFIG_USB_MTU3` | y | **not set** |
| `CONFIG_USB_MTU3_GADGET` | y | **not set** |
| `CONFIG_USB_MUSB_HDRC` | not set | **y** |
| `CONFIG_USB_MUSB_MEDIATEK` | — | **y**（新增） |
| `CONFIG_USB_MUSB_GADGET` | — | **y**（新增） |
| `CONFIG_USB_CONFIGFS_SERIAL` | not set | **y**（adb 需要） |
| `CONFIG_USB_CONFIGFS_F_FS` | not set | **y**（ffs.adb 需要） |

其余保持 yao 的 4420 行配置不变。

---

## 三、下一步（未做）

### L1 能启动
1. 复制补丁到内核源码（pinctrl-mt6755.c 等）
2. CI 编译 Image.gz + dtb
3. bootimg.py 打包（注意你的 boot 是标准 v0 头，MTK 扩展头为 0）
4. fastboot flash boot（16 MB，余 5.68 MB）

### L2 完整服务器
- cpufreq：m681 `mt_cpufreq.c` 移植
- thermal：m681 50 文件
- 电池：BQ25890 主线驱动 + m681 `cust_battery_meter`
- WiFi：`mt6750-connsys` forward-port

---

## 四、关键事实（来自实测与调查）

- SoC: MT6755V/CM，8×A53，PMIC MT6351/MT6353
- USB: musb-hdrc @ 0x11270000，GIC_SPI 72（不是 mtu3）
- eMMC: msdc0 @ 0x11230000，bus-width 4
- boot: 16 MB，标准 v0 头，tags_addr=0x44000000，当前占用 10.32 MB
- 充电 IC: BQ25890 @ i2c1 0x6b
- WiFi: CONSYS 架构，固件 WIFI_RAM_CODE_6755 等

---

*本文件只记录已完成的改动，未编译、未刷机、未改任何仓库。*
