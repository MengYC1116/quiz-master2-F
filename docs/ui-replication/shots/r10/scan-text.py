#!/usr/bin/env python3
"""像素扫描定位：从学科管理/设置页截图的内容区里找出文字行的 Y 中心。

用法：scan-text.py <page-*.png> [x0 x1]
原理：取内容区 x∈[x0,x1]（默认 300-1250），逐行统计与背景色差异大
的像素（文字），把连续有文字的行合并成带，输出每带的 y 起止与中心。
用于定位学科行 / 章节行 / 搜索框等行内控件的 Y。只做定位，不改图。
"""
import sys
from collections import Counter

from PIL import Image


def main() -> None:
    path = sys.argv[1]
    x0 = int(sys.argv[2]) if len(sys.argv) > 2 else 300
    x1 = int(sys.argv[3]) if len(sys.argv) > 3 else 1250
    im = Image.open(path).convert('RGB')
    w, h = im.size
    px = im.load()
    bg = Counter(
        px[x, y] for x in range(x0, x1, 7) for y in range(0, h, 7)
    ).most_common(1)[0][0]

    def is_text(x, y):
        r, g, b = px[x, y]
        br, bg_, bb = bg
        return abs(r - br) + abs(g - bg_) + abs(b - bb) > 90

    bands = []
    y = 0
    while y < h:
        n = sum(1 for x in range(x0, x1, 2) if is_text(x, y))
        if n >= 2:
            y0 = y
            while y < h and (
                sum(1 for x in range(x0, x1, 2) if is_text(x, y)) >= 2
                or (y - y0 < 40
                    and sum(
                        1
                        for x in range(x0, x1, 2)
                        if is_text(x, min(y + 3, h - 1))
                    ) >= 2)
            ):
                y += 1
            bands.append((y0, y - 1))
        else:
            y += 1
    for i, (y0, y1) in enumerate(bands):
        print(f'band {i}: y {y0}-{y1} center {(y0 + y1) // 2}')


if __name__ == '__main__':
    main()
