# 首次 boot.img 打包记录（2026-11-26）

## 产物
- 文件: `release/boot-mainline-m5note.img`
- 大小: 9,990,144 字节 = 9.53 MB（boot 分区 16.8 MB，余量充足）
- SHA256: `ba4405c05904f52bda7324dcb3ce0d7ff4052068d44fc6ff04de9dd701f6e5c6`

## 构成
| 部分 | 来源 | 大小 |
|---|---|---|
| boot 头（含 MTK 私有字段） | 设备 p22 只读 dd | 2048 B |
| kernel = Image.gz + DTB | CI run 45790670725 产物拆分 | 8.96 MB |
| ramdisk = busybox + init-direct | busybox 从 /data/debian/bin 只读拉取 | 1.02 MB |

## 校验（全部通过）
- magic ANDROID! ✅
- cmdline: bootopt=64S3,32N2,64N2（原厂）✅
- tags_addr=0x44000000 ✅
- kernel gzip 解压 OK，DTB magic d00dfeed ✅
- DTB 含 meizu,m5note + ti,bq25890 ✅
- ramdisk newc cpio，含 init + 静态 busybox(aarch64) ✅
- SHA1 头内与重算一致 ✅

## 启动逻辑（ramdisk /init）
mount /data(p31) → switch_root /data/debian /sbin/init → systemd

## 未刷机，警告
- 首次刷前务必备份原 boot：`dd if=/dev/block/mmcblk0p22 of=/sdcard/boot.img.bak`
- 用 SP Flash Tool 时核对：9.53MB 的 img 填 boot 行，别填 lk 行
