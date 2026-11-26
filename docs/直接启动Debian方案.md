# M5 Note 直接启动 Debian 打包方案（最终版 2026-11-26）

## 目标（用户明确）
刷 **boot 分区**（不是 TWRP），mainline 内核起来后**直接启动现有 Debian**，不再经安卓 chroot。

## 关键发现（ADB + SSH 实测）
| 项 | 值 | 来源 |
|---|---|---|
| Debian rootfs 实体 | **`/data/debian`，4.3 GB** | ADB(TWRP侧) `ls`+`du` |
| 所在分区 | mmcblk0p31（`/data`，ext4，27GB，21G 空闲） | `/proc/mounts` |
| 系统 | Debian 13 trixie，hostname `AnLinux-Debian` | `etc/os-release` |
| init | `/sbin/init` → `../lib/systemd/systemd`（133KB） | `ls -l` |
| sshd | `ssh.service` 已启用 | `etc/systemd/system/multi-user.target.wants/` |
| 用户当前怎么跑 | Android/TWRP 里 `chroot /data/debian`，proc/sys/dev bind 进去 | TWRP mount 列表 |
| **静态 busybox** | **`/data/debian/bin/busybox` 1.37.0，STATIC，有 switch_root/mount/sh** | readelf 无 INTERP |

## 为什么不需要造 rootfs / 编译 busybox
- rootfs 是现成的完整 Debian（4.3G，systemd+sshd+apt 全在 /data 分区，持久）
- 静态 busybox 现成（在 Debian 里），拷到 ramdisk 即可当 init
- 之前写的 tablet-init.sh / init.sh（k50v1 的 Debian-in-userdata 方案）**作废**

## 打包链路（3 样输入 → 1 个 boot.img）
```
输入1: CI 产物 Image.gz + mt6755-m5note.dtb   ← 已有（run 45790670725）
输入2: /data/debian/bin/busybox（静态）         ← 设备上现成，adb pull
输入3: init-direct 脚本                         ← 已写好（下面）
      ↓
ramdisk.cpio.gz = { /init, /bin/busybox }       ← 极小，<2MB
      ↓
boot.img = 原厂头(2KB,保留MTK私有字段) + Image.gz+DTB + ramdisk
```

## init-direct 逻辑（ramdisk 里的 /init）
```sh
1. busybox --install -s；mount proc/sys/dev
2. 等 /dev/mmcblk0p31 出现
3. mount -t ext4 -o rw /dev/block/mmcblk0p31 /data
4. 确认 /data/debian/sbin/init 存在
5. mount --move proc/sys/dev 到 /data/debian/{proc,sys,dev}
6. exec busybox switch_root /data/debian /sbin/init   ← systemd 接管
```
（和 TWRP 现有 chroot 的 bind 方式一致，只是改成直接当 PID 1）

## 具体步骤（物料齐了就能跑，现在不执行）

### 1. 从 CI 产物拆出 Image.gz 和 DTB
`Image.gz-dtb` 里 FDT magic `d00dfeed` 之前是 Image.gz，之后是 DTB。

### 2. 从设备取静态 busybox（只读，adb pull）
```
adb -s 192.168.31.213:5555 pull /data/debian/bin/busybox busybox
```

### 3. 取原厂 boot 头（只读 dd）
```
adb -s 192.168.31.213:5555 shell 'dd if=/dev/block/mmcblk0p22 bs=1M count=16' > boot-stock.img
```

### 4. 生成 ramdisk
```
mkdir -p rd/bin
cp busybox rd/bin/busybox
cp init-direct rd/init && chmod +x rd/init
(cd rd && find . | cpio -o -H newc --owner=0:0 | gzip -9) > ramdisk.cpio.gz
```

### 5. 套原厂头打包（复用 mkimage-m5note.sh 的核心逻辑）
- hdr = bytearray(stock[:2048])  # 保留 MTK 私有字段 1644/1648/1652
- 改 kernel_size/ramdisk_size、重算 SHA1
- kernel = Image.gz + DTB

## 体积
- kernel 8.55MB + ramdisk <2MB ≈ **10.5MB < 16.8MB** ✅

## 启动后会发生什么（预测）
- 最好：mainline 内核 → init → mount /data → switch_root → systemd → sshd → 你要的服务器
- 中间：卡在 mount/switch_root → 看 kmsg/ramoops（我只保留串口能力，但 M5 Note 未必引出串口）
- 最坏：起不来 → 进 recovery 刷回原 boot.img（**刷前必备份 p22**）

## 风险与未验证
- init 脚本逻辑与 TWRP chroot 一致，但**没实机跑过**
- systemd 在 mainline 7.3.1 上能否完全起来（udev/网络）要实测
- WiFi 固件需从你 vendor 分区提供（仓库合规不含）

## 状态
- 脚本/文档就绪，物料（busybox、boot头、Image.gz）都能拿到
- 未实际打包、未刷机（按用户要求）
