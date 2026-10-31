"""生成 App 图标（纯 Python，不依赖 Pillow）。

1024x1024 紫色渐变底 + 三条白色台本横条 + 一个红点，
和安卓版的气质接近。输出 ios-app/Tidanci/Assets.xcassets/AppIcon.appiconset/icon1024.png
"""

import math
import os
import struct
import zlib

W = H = 1024
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "Tidanci", "Assets.xcassets", "AppIcon.appiconset", "icon1024.png")

# #6C5CE7 -> #9B8CFF 对角渐变
C0 = (0x6C, 0x5C, 0xE7)
C1 = (0x9B, 0x8C, 0xFF)
RED = (0xE5, 0x48, 0x4D)


def lerp(a, b, t):
    return int(round(a + (b - a) * t))


def bar(px, py, x0, x1, yc, h):
    """圆角横条：返回该像素在条内的覆盖度（0~1，做一点抗锯齿）"""
    r = h / 2.0
    cx = min(max(px, x0 + r), x1 - r)
    cy = yc
    d = math.hypot(px - cx, py - cy)
    if d <= r - 1:
        return 1.0
    if d >= r + 1:
        return 0.0
    return (r + 1 - d) / 2.0


def disc(px, py, cx, cy, r):
    d = math.hypot(px - cx, py - cy)
    if d <= r - 1:
        return 1.0
    if d >= r + 1:
        return 0.0
    return (r + 1 - d) / 2.0


def build():
    raw = bytearray()
    for y in range(H):
        raw.append(0)  # filter: none
        for x in range(W):
            t = (x + y) / (2.0 * (W - 1))
            r = lerp(C0[0], C1[0], t)
            g = lerp(C0[1], C1[1], t)
            b = lerp(C0[2], C1[2], t)

            # 三条横条，模拟台本
            a = 0.0
            a = max(a, bar(x, y, 232, 792, 372, 66))
            a = max(a, bar(x, y, 232, 664, 502, 66))
            a = max(a, bar(x, y, 232, 560, 632, 66))
            if a > 0:
                r = lerp(r, 255, min(1.0, a))
                g = lerp(g, 255, min(1.0, a))
                b = lerp(b, 255, min(1.0, a))

            # 右下角的红色录制点
            d = disc(x, y, 772, 774, 74)
            if d > 0:
                r = lerp(r, RED[0], d)
                g = lerp(g, RED[1], d)
                b = lerp(b, RED[2], d)

            raw += bytes((r, g, b, 255))
    return bytes(raw)


def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    ihdr = struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(build(), 9))
           + chunk(b"IEND", b""))
    with open(OUT, "wb") as f:
        f.write(png)
    print("写出", OUT, len(png), "bytes")


if __name__ == "__main__":
    main()
