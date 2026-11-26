# 手把手：把一台 MT6755 老安卓机移植到主线 Linux 内核（第 0 版：从选型到编出 boot.img）

> 平台：魅蓝 Note5（Meizu M5 Note）/ MT6755 (Helio P10) / 2.8GB RAM / eMMC 31GB
> 内核：Linux 7.3.1（主线）+ 社区 board bring-up 补丁
> 目标：headless 服务器内核（网络 + Docker + 充电 + 电量计），屏幕放弃
> 时间跨度：几天（不是几周、不是几年）
> 状态：编译与打包完成；刷机运行未验证（本文如实标注）

这是一篇实战记录，不是理论教程。它讲清楚一个真实问题：**没有厂商主线支持的老手机，怎么用"站在别人肩上"的方式，几天内做出一个能编过、能打包的内核**，以及哪些坑我踩了、哪些结论我一开始是错的。

---

## 一、先想清楚：你到底要"主线"还是"能跑"

这两个目标经常冲突。本次的实际取舍：

- 要主线（用户原话："我就是要追求主线"），那就接受：厂商 hal、专有驱动、GPU、显示基本拿不到。
- 要服务器（Docker/LXC、网络、充电、电量计）——这些恰好是主线原生或社区已经做过的部分。
- 屏幕：原厂 fb 是 lk 初始化的，物理地址未知；真 LCD 驱动要重写 panel 序列。**能轻松加就加，不行就算**——最后放弃。

结论先行：**headless 服务器 + 主线是这几天内现实可交付的组合**。想要"所有硬件都工作"，天数不够。

---

## 二、方法论：不要逆向，要"移植 + 挑版本"

### 1. 判断资料是否齐全

第一步不是读代码，是查"有没有人做过同 SoC"。本次查到：

- 原厂 GPL 源码（3.10.72，2041 个 mt6755 文件）——证明不需要逆向寄存器（但版本太老，不建议直接往上堆）。
- 社区两个 bring-up 项目：一个基于 6.12（引导/eMMC/pinctrl/USB/电池可用，WiFi 不通），一个基于 7.3.1（WiFi/BT/GPS/充电/电量全套可用）。

**关键决策：选 7.3.1 的 pminervini/linux-mt6750-tablet。** 理由：它的 WiFi 内核模块就是针对 7.2/7.3 的 cfg80211 API 写的。

### 2. 血的教训：不要手工 backport 不匹配的 API

我最初用 6.12 内核，然后试图把 7.x 的 CONSYS WiFi 驱动往 6.12 上改：

```
struct wireless_dev *wdev  →  net_device *ndev
u64 cookie                 →  u64 *cookie
rx_addr、timer_container_of、tickfn……
```

一轮一轮改，一轮一轮编译报错。根因不是我水平问题，是**驱动版本和内核 API 版本不匹配**。正确做法：**让内核版本去适配经过验证的驱动，而不是反过来**。换到 7.3.1 后，这些错误全部消失，一行代码都没改。

这就是本次最重要的方法论：
> **先看别人在什么内核版本上跑通了全套，就用那个版本；不要相信"我改改 API 就能从上一个版本挪过来"。**

### 3. 来源核验（正规性）

我做的核验，你可以照抄：

- 33 个补丁（git format-patch 格式）逐个算 md5，和上游 GitHub 仓库对比——必须一致。
- 外编驱动源码（CONSYS WiFi）和解压的原始副本 `diff -rq`——必须零差异。
- 内核 tarball 用清华镜像，官方稳定版。
- 设备参数（内存/充电 IC/i2c 地址/USB 控制器/分区表）全部从设备 `/sys/firmware/devicetree/base`、`/proc`、`parted` **只读**读取。

任何"我觉得应该是这样"的参数，都要回到设备上去读。我一开始把充电电压拍成 4.4V/1.5A，后来读设备发现满充 4.37V、`high_battery_voltage_support=0`，改成 4.35V/1A。

---

## 三、工程化：CI 与增量编译

老设备移植的循环是"改一点 → 编译 → 看错误"。全量编译 14–16 分钟，根本没法迭代。所以必须上增量缓存。

### 1. GitHub Actions 结构

- `workflow_dispatch` 手动触发（不要 push 就跑，浪费额度）。
- 缓存内核源码 tarball（key 固定）。
- 缓存整棵 build tree（linux + out）成 `build-tree.tar`，key 用 `buildtree-7.3.1-${{ github.run_id }}`，restore-keys 用前缀。
- 全量首次 14–16 分钟；命中缓存后 ~2.5 分钟（大头是 2.6G 的 tar 上传下载）。

### 2. 一个隐蔽的坑：补丁已应用的判定

我一开始用 `git log | grep "PATCH 33/33"` 判断补丁有没有打过——**永远判定失败**。因为 `git am` 会把 subject 里的 `[PATCH 33/33]` 剥掉。

正确做法：用补丁创建的**标记文件**判断，例如：

```bash
if [ -f linux/drivers/tty/serial/earlycon-ram.c ]; then
    echo "补丁已打，跳过"
else
    cd linux && git am --whitespace=nowarn ../patches/*.patch
fi
```

### 3. 另一类坑：sed 里的 `&`

往 dts 里改 `stdout-path = &framebuffer0;` → `&uart0;`，sed 替换串里的 `&` 表示"整个匹配"，不转义就生成非法 dts。写成 `\&`。这类错看起来很蠢，但它会让你在 CI 里浪费好几轮。

---

## 四、板级适配：把别人的板子改成你的

### 1. 千万别用空骨架 dts

我最初从上游补丁里抽出一份"干净 dts"，结果里面没有 i2c、时钟、USB PHY 节点——因为上游把这些节点**追加在它自己的板级 dts 里**，而不是 dtsi 里。编译直接报 `Label or path /soc/i2c@11008000 not found`。

正确做法：**从"打完全部补丁后的完整 dts"派生**，而不是从中间态派生：

```bash
BASE=linux/arch/arm64/boot/dts/mediatek/mt6750-k50v1-tablet.dts
cp "$BASE" "$OUT"
sed -i 's|MT6750 tablet k50v1|Meizu M5 Note|g' "$OUT"
sed -i 's|mediatek,k50v1-tablet|meizu,m5note|g' "$OUT"
# 内存 512M → 2.8G（lk 也会覆盖）
sed -i 's|0x0 0x80000000>;|0x0 0xb0000000>;|' "$OUT"
```

### 2. 充电：先查内核有没有原生驱动，再谈自己写

我差点自己写 BQ25890 驱动。实际上 Linux 7.3.1 有原生 `drivers/power/supply/bq25890_charger.c`（`CONFIG_CHARGER_BQ25890`）。**只查 config 不算查，要查 drivers 目录和 Kconfig。**

打开选项 + dts 加节点即可：

```dts
&{/} {
    i2c1: i2c@11008000 {
        compatible = "mediatek,mt6755-i2c";
        reg = <0 0x11008000 0 0x1000>, <0 0x11000180 0 0x80>;
        interrupts = <GIC_SPI 85 IRQ_TYPE_LEVEL_LOW>;
        clocks = <&i2c_src_clk>, <&clk26m_ref>;
        clock-names = "main", "dma";
        clock-div = <10>;
        #address-cells = <1>;
        #size-cells = <0>;
        bq25890@6b {
            compatible = "ti,bq25890";
            reg = <0x6b>;
            ti,battery-regulation-voltage = <4350000>; /* 4.35V, 实测 stock 满充 4.37V */
            ti,charge-current = <1000000>;             /* 1A, 保守值 */
            status = "okay";
        };
    };
};
```

注意：`i2c1` 这个 label 不能随便用，上游 dts 里的 lk-overlay-sink 可能占用了同名 label；用完整路径引用或新 label。

### 3. 用产物反查验证，而不是信源码

编完后从 `Image.gz-dtb` 里找 FDT magic `d00dfeed`，解析 dtb 字符串块，确认：

```
meizu,m5note        FOUND
mediatek,mt6755     FOUND
ti,bq25890          FOUND
ti,battery-regulation-voltage = 4350000
ti,charge-current = 1000000
```

reserved-memory 和 lk 保留区做区间重叠检测——必须为 0。

---

## 五、从内核到 boot.img

### 1. 涉及的三样东西

- 内核：`Image.gz`（gzip 压缩）+ DTB，拼接成 `Image.gz-dtb`。
- ramdisk：一个极简 init + 静态 busybox。本项目的 init 逻辑是"挂载 /data 分区 → switch_root 到 /data/debian → systemd 接管"。
- boot 头：从设备 boot 分区只读 dd 出来 16MB，脚本只替换 kernel/ramdisk 长度字段并重算 SHA1，**完整保留厂商私有扩展字段**（MTK 的 1644/1648/1652 偏移有 dtbo 相关字段，乱写 lk 会 panic）。

### 2. 一个常被忽略的事实：内建 y vs 模块 m

`CONFIG_CFG80211=y` 和 `=m` 的区别，决定驱动是在 `Image.gz` 里，还是在你必须装进 rootfs 的 `.ko` 里。

本项目里 WiFi 是 4 个 `.ko`（cfg80211、wlan_gen2、mtk_wmt_wifi_soc、mtk_stp_wmt_soc）。**编译产物里有 ≠ rootfs 里有**：设备的 `/lib/modules` 是空的，所以现在刷上去 WiFi 确定起不来。这是项目收尾时最该记住的一条——**编译成功不等于功能可用，模块必须落到 rootfs 并 depmod**。

### 3. 打包脚本的核心（Python）

```python
hdr = bytearray(stock_boot[:page])          # 保留原厂全部私有字段
struct.pack_into('<I', hdr, 8, len(kernel))   # kernel_size
struct.pack_into('<I', hdr, 16, len(rd))      # ramdisk_size
# SHA1: 按顺序 update(blob) + update(struct.pack('<I', len(blob)))
hdr[576:608] = sha.digest().ljust(32, b'\0')
img = bytes(hdr) + pad(kernel) + pad(rd)
```

`tags_addr` 必须等于 lk 给 DTB 的地址（本项目 0x44000000），否则 lk 直接 panic。

---

## 六、调试通道：刷机前先想好"失败了怎么看"

这是最容易被忽略、但最要命的一环。老手机往往没有可达串口：

- 本项目内核里带了一个 **RAM console**：强制从 `setup_arch()` 早期把 printk 写进物理内存 `0xb00d0000`（64KB 环形缓冲），并在 `0xb00c0000` 写 "HEAD" marker 证明内核被跳起来；对应 reserved-memory 必须覆盖这段地址。
- 读它要靠 bootrom/DA 模式（mtkclient 的 `da peek`），不是普通 adb shell。
- 本机 stock 下 SSH/ADB 都走 WiFi（wlan0）；mainline 下 WiFi 模块没装，就没有网络——失败时是"哑巴"，所以带外日志手段必须先准备好。

教训：**在讨论"能不能刷"之前，先回答"刷失败了拿什么看错误"。**

---

## 七、屏幕为什么放弃（能轻松加就加，不行就算）

三种"屏幕"要分清：

1. **simple-framebuffer**：lk 已经点亮屏并留下 fb，内核只映射它，不需要写 LCD 驱动。上游能这么做是因为 fb 物理地址固定在 dts（`0x7f190000`）。本机 reserved-memory 里没有 fb 节点，地址未知 → 卡死。
2. **Panfrost GPU + simpledrm**：上游有有限验证，但针对它自己的 JD9365D DSI 屏；换屏要重做 panel 初始化/时序，难度高。
3. **从零写 panel 驱动**：要反编译 stock 的 panel 序列，几天内不现实。

结论：headless 目标下，屏幕不值得投入；本项目的 boot.img 没有显示。

---

## 八、成果与状态（如实）

已验证（实物）：
- 内核 7.3.1 + 33 个 md5 核对过的社区补丁，CI 编译成功
- 容器/网络/USB mtu3/充电 BQ25890/电量计/温控全部编进内核
- M5 Note DTB 从产物读回验证，reserved-memory 零重叠
- boot.img 9.53MB，头/DTB/ramdisk/SHA1 全校验通过
- 502 个内核模块打包成 bundle 发布

未验证：
- **从未刷机**；systemd、USB 网络、WiFi 实际运行都是未知数
- WiFi 模块未装进设备 `/lib/modules`，现状刷上去 WiFi 不可用

所以标题里的"移植编译"是真的，"能跑"没有声明。把"编过了"包装成"成功了"是自欺欺人。

---

## 九、方法论总结（可复用清单）

1. 先查同 SoC 是否有人跑通全套；**选别人验证过的内核版本**，不要手工 backport API。
2. 资料核验：md5/diff 逐字节对齐上游；设备参数只读实测。
3. 参数不拍脑袋：电压/电流/地址/内存都从设备读。
4. CI 必上增量缓存；补丁判定用标记文件不用 git log。
5. dts 从"打完全部补丁的完整文件"派生；sed 特殊字符转义。
6. 先查内核原生驱动有没有，再决定写不写驱动；区分 `=y` 和 `=m`，模块要落 rootfs。
7. 用产物（dtb 二进制）反查验证，不只信源码。
8. boot 头完整复用原厂，只改长度和 SHA1，tags_addr 对齐 lk。
9. 刷机前先准备带外调试（RAM console / DA peek）。
10. **"编译成功"和"功能可用"之间，隔着一整个 rootfs 和一次真机启动。**

---

*本文是实战记录，对应仓库：`chentianxiong123/mt6755-m5note`。早期两篇讨论总结（`MT6755-主线化讨论总结.md`、`MT6755-移植资料齐全性总结.md`）里的部分结论（如"USB 是 musb""预计 1-2 周"）已被本文的实测数据修正，以本文为准。*
