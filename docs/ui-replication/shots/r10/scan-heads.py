#!/usr/bin/env python3
"""像素扫描定位：从学科管理/设置页截图里找出分段折叠头的 Y 中心。

用法：scan-heads.py <page-*.png>
原理：内容区 x∈[300,1250]，逐行统计与页面背景色差异大的像素；
折叠头是整行宽的 surface-2 填充条（计数 > 800 的行），把连续行
合并成带，输出每带的 y 起止与中心。只做定位，不改图。
"""
import sys
from collections import Counter

from PIL import Image


def main() -> None:
    path = sys.argv[1]
    im = Image.open(path).convert('RGB')
    w, h = im.size
    px = im.load()
    bg = Counter(
        px[x, y] for x in range(300, 1250, 7) for y in range(0, h, 7)
    ).most_common(1)[0][0]

    def is_bar(x, y):
        r, g, b = px[x, y]
        br, bg_, bb = bg
        return abs(r - br) + abs(g - bg_) + abs(b - bb) > 12

    bands = []
    y = 0
    while y < h:
        n = sum(1 for x in range(300, 1250, 2) if is_bar(x, y))
        if n >= 400:
            y0 = y
            while y < h and sum(
                1 for x in range(300, 1250, 2) if is_bar(x, y)
            ) >= 400:
                y += 1
            bands.append((y0, y - 1))
        else:
            y += 1
    for i, (y0, y1) in enumerate(bands):
        print(f'head {i}: y {y0}-{y1} center {(y0 + y1) // 2}')


if __name__ == '__main__':
    main()
