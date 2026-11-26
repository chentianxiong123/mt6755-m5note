"""check-dtb-m5note.py <dtb>: M5 Note 版 DTB 校验。

与 pminervini 原版差异：跳过 ov0.dtbo overlay 检查。
依据：M5 Note 的 GPT 分区表（parted 实测 32 个分区）没有 odmdtbo 分区，
lk 读不到 overlay 会跳过，不存在 "label 缺失 ASSERT" 风险。
保留两项检查：__symbols__ 存在（lk 可能引用）、reserved-memory 不与 lk mblock 重叠。
"""
import subprocess, sys

dtb = sys.argv[1]

# 1) __symbols__ 必须存在（lk overlay/引用需要，保留无害）
syms = subprocess.run(['fdtget', '-l', dtb, '/'], capture_output=True, text=True).stdout.split()
if '__symbols__' not in syms:
    sys.exit('FAIL no __symbols__')

# 2) reserved-memory 不与 lk 的 mblock 保留区重叠
#    注意：M5 Note 实测内存 2.8G，lk 保留区基址和 k50v1 相同（小地址区），列表沿用
LK = [(0x7ff80000, 0x80000, 'log_store'), (0x44600000, 0x40000, 'atf'), (0x7ff40000, 0x40000, 'atf-log'),
      (0x44000000, 0x80000, 'dtb'), (0x40080000, 0x3200000, 'kernel'), (0x45000000, 0x1000000, 'ramdisk'),
      (0x7f190000, 0xdb0000, 'framebuffer'), (0x98000000, 0x20000, 'ccci'), (0x8e000000, 0xa000000, 'ccci-md'),
      (0xbffff000, 0x1000, 'dram-dummy')]
#    最后一项 dram-dummy 按 4G 顶端算；M5 Note 2.8G 到 0xffffffff 不适用，
#    但内核保留区都远低于它，无影响，保留即可。
nodes = subprocess.run(['fdtget', '-l', dtb, '/reserved-memory'], capture_output=True, text=True).stdout.split()
bad = 0
for n in nodes:
    r = subprocess.run(['fdtget', '-t', 'x', dtb, f'/reserved-memory/{n}', 'reg'], capture_output=True, text=True)
    if r.returncode:
        continue
    v = [int(x, 16) for x in r.stdout.split()]
    for i in range(0, len(v), 4):
        a, s = (v[i] << 32) | v[i + 1], (v[i + 2] << 32) | v[i + 3]
        for la, ls, ln in LK:
            if a < la + ls and la < a + s:
                print(f'FAIL {n} {a:#x}+{s:#x} overlaps lk {ln}'); bad = 1
if bad:
    sys.exit(1)
print('dtb ok for lk (overlay check skipped: no odmdtbo partition on M5 Note)')
