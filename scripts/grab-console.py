#!/usr/bin/env python3
"""Capture the live kmscon console framebuffer to a PNG.

kmscon draws via DRM/KMS, NOT via /dev/fb0 - on this Pi fb0 reads blank=4
(powered down) with zero holders, so fbgrab/fbcat would capture a stale black
buffer. The real pixels live in a GEM object whose PHYSICAL address is exposed
in DRM debugfs. We read that region out of /dev/mem.

Writes a PNG with no external dependencies (zlib + struct only).
"""
import re, os, sys, zlib, struct, mmap, subprocess

CARD = sys.argv[1] if len(sys.argv) > 1 else "1"
OUT  = sys.argv[2] if len(sys.argv) > 2 else "/tmp/console.png"

txt = open(f"/sys/kernel/debug/dri/{CARD}/framebuffer").read()

# Parse each framebuffer[N] block; keep kmscon's largest live one.
best = None
for block in txt.split("framebuffer[")[1:]:
    if "allocated by = kmscon" not in block:
        continue
    m_size = re.search(r"size=(\d+)x(\d+)", block)
    m_pitch = re.search(r"pitch\[0\]=(\d+)", block)
    m_dma  = re.search(r"dma_addr=0x([0-9a-fA-F]+)", block)
    m_fmt  = re.search(r"format=(\w+)", block)
    if not (m_size and m_pitch and m_dma):
        continue
    w, h = int(m_size.group(1)), int(m_size.group(2))
    dma = int(m_dma.group(1), 16)
    if dma == 0:
        continue
    cand = (w * h, w, h, int(m_pitch.group(1)), dma, m_fmt.group(1) if m_fmt else "?")
    if best is None or cand[0] > best[0]:
        best = cand

if not best:
    sys.exit("no kmscon framebuffer with a usable dma_addr found")

_, W, H, PITCH, DMA, FMT = best
print(f"fb: {W}x{H} pitch={PITCH} fmt={FMT} dma=0x{DMA:x}", file=sys.stderr)

# ☠️ On the Pi 4, dma_addr from debugfs is a VideoCore BUS address, not a CPU
# physical address. Reading it verbatim out of /dev/mem returns unrelated RAM -
# which decodes to convincing-looking colour NOISE, not an obviously-wrong black
# frame. Strip the 0xC0000000 alias to get the CPU physical address.
# Sanity check: a real console frame is hugely compressible (zlib ratio ~0.005);
# wrong memory is incompressible (~0.985).
BUS_ALIAS = 0xC0000000
phys = DMA - BUS_ALIAS if DMA >= BUS_ALIAS else DMA

length = PITCH * H
pagesize = mmap.PAGESIZE
offset = phys & ~(pagesize - 1)
delta = phys - offset

fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
mm = mmap.mmap(fd, length + delta, mmap.MAP_SHARED, mmap.PROT_READ, offset=offset)
raw = mm[delta:delta + length]
mm.close(); os.close(fd)

# XR24 = little-endian XRGB8888 -> bytes per pixel are B,G,R,X
rows = bytearray()
for y in range(H):
    row = raw[y * PITCH : y * PITCH + W * 4]
    rows.append(0)                      # PNG filter type 0
    # build RGB row
    px = bytearray(W * 3)
    for x in range(W):
        b, g, r = row[x*4], row[x*4+1], row[x*4+2]
        px[x*3], px[x*3+1], px[x*3+2] = r, g, b
    rows.extend(px)

def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data +
            struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))

import zlib as _z
ratio = len(_z.compress(bytes(rows[:200000]), 6)) / min(200000, len(rows))
if ratio > 0.5:
    print(f"WARNING: capture is incompressible (ratio {ratio:.3f}) - this looks "
          f"like NOISE from the wrong memory region, not a console frame.",
          file=sys.stderr)

png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(bytes(rows), 6))
       + chunk(b"IEND", b""))
open(OUT, "wb").write(png)
print(f"wrote {OUT} ({len(png)} bytes)", file=sys.stderr)
