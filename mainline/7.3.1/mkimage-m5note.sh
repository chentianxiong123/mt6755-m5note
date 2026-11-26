#!/bin/bash
# M5 Note 专用 boot.img 打包脚本（基于 pminervini mkimage.sh 适配）
# usage: ./mkimage-m5note.sh <tag>  -> release/boot-mainline-m5note-<tag>.img
#
# 与 k50v1 原版的差异：
#  1. DTB 文件名 mt6755-m5note.dtb（不是 k50v1）
#  2. check-dtb 跳过 ov0.dtbo overlay（M5 Note GPT 无 odmdtbo 分区），保留 reserved-memory 检查
#  3. 复用你设备的 stock boot.img 头（原厂 cmdline），保留 MTK 私有扩展字段
set -euo pipefail
cd "$(dirname "$0")"
TAG=${1:?tag}

# ---- 物料检查 ----
need() { [ -f "$1" ] || { echo "缺物料: $1"; echo "见 docs/打包方案.md 的物料清单"; exit 1; }; }
need dl/busybox/x/usr/bin/busybox
need images/boot-stock.img
need out/arch/arm64/boot/Image.gz
need out/arch/arm64/boot/dts/mediatek/mt6755-m5note.dtb

# ---- 1. 构建 initramfs ----
R=initramfs/root
rm -rf $R && mkdir -p $R/{bin,proc,sys,dev,pstore,mnt,tmp}
cp dl/busybox/x/usr/bin/busybox $R/bin/busybox
install -m 755 initramfs/init.sh $R/init
install -m 755 initramfs/tablet-init.sh $R/tablet-init
(cd $R && find . | cpio -o -H newc --owner=0:0 --quiet | gzip -9) > initramfs/initramfs.cpio.gz

# ---- 2. DTB 检查（M5 Note 版：跳过 overlay，保留 reserved-memory）----
mkdir -p release
DTB=out/arch/arm64/boot/dts/mediatek/mt6755-m5note.dtb
python3 -I check-dtb-m5note.py $DTB || { echo "DTB REJECTED, not packing"; exit 1; }
cat out/arch/arm64/boot/Image.gz $DTB > out/Image.gz-dtb

# ---- 3. 复用 stock 头打包 ----
python3 -I - out/Image.gz-dtb initramfs/initramfs.cpio.gz images/boot-stock.img release/boot-mainline-m5note-$TAG.img <<'EOF'
import struct, hashlib, sys
kern, rd, base, out = sys.argv[1:5]
d = open(base, 'rb').read()
assert d[:8] == b'ANDROID!'
ks, ka, rs, ra, ss, sa, ta, ps = struct.unpack('<8I', d[8:40])
kernel = open(kern, 'rb').read(); ramdisk = open(rd, 'rb').read()
pad = lambda b: b + b'\0' * (-len(b) % ps)
hdr = bytearray(d[:ps])  # 完整复制原厂头（含 MTK 私有扩展字段 1644/1648/1652）
struct.pack_into('<I', hdr, 8, len(kernel))
struct.pack_into('<I', hdr, 16, len(ramdisk))
struct.pack_into('<I', hdr, 24, 0)  # no second stage
sha = hashlib.sha1()
for blob in (kernel, ramdisk, b''):
    sha.update(blob); sha.update(struct.pack('<I', len(blob)))
hdr[576:608] = sha.digest().ljust(32, b'\0')
img = bytes(hdr) + pad(kernel) + pad(ramdisk)
assert len(img) <= 16 << 20, f'image too big: {len(img)}'
open(out, 'wb').write(img)
print(f'{out}: kernel {len(kernel)} ramdisk {len(ramdisk)} total {len(img)} cmdline {hdr[64:576].split(bytes(1))[0]}')
EOF

# ---- 4. 校验打进去的 DTB 就是检查过的那个 ----
python3 -I - release/boot-mainline-m5note-$TAG.img $DTB <<'EOF' || { rm -f release/boot-mainline-m5note-$TAG.img; echo "PACKED DTB MISMATCH, image removed"; exit 1; }
import struct, sys, zlib
d = open(sys.argv[1], 'rb').read(); dtb = open(sys.argv[2], 'rb').read()
ksz, page = struct.unpack_from('<I', d, 8)[0], struct.unpack_from('<I', d, 36)[0]
z = zlib.decompressobj(31); z.decompress(d[page:page + ksz])
sys.exit(0 if z.unused_data == dtb else 1)
EOF
sha256sum release/boot-mainline-m5note-$TAG.img
