#!/usr/bin/env python3
"""像素扫描定位：从探针首页截图里找出左导航各文字行的 Y 中心。

用法：scan-nav.py <probe-home-*.png>
原理：取导航条 x∈[30,190]，逐行统计与背景色差异大的像素（文字），
把连续有文字的行合并成带，输出每带的 y 起止与中心。带按从上到下排：
品牌标题、品牌副标题、7 个导航项、学科速览标题/行、设置按钮。
导航项顺序固定：首页、收集中心、整理工作台、错题本、复习、学习报告、
学科管理——第 6 个导航带即“学习报告”。
只做定位，不改图。
"""
import sys

from PIL import Image


def main() -> None:
    path = sys.argv[1]
    im = Image.open(path).convert('RGB')
    w, h = im.size
    px = im.load()
    # 背景色取导航条中部最常见的颜色。
    from collections import Counter

    bg = Counter(
        px[x, y] for x in range(30, 190, 7) for y in range(0, h, 7)
    ).most_common(1)[0][0]

    def is_text(x, y):
        r, g, b = px[x, y]
        br, bg_, bb = bg
        return abs(r - br) + abs(g - bg_) + abs(b - bb) > 90

    bands = []
    y = 0
    while y < h:
        n = sum(1 for x in range(30, 190, 2) if is_text(x, y))
        if n >= 2:
            y0 = y
            while y < h and (
                sum(1 for x in range(30, 190, 2) if is_text(x, y)) >= 2
                or (y - y0 < 40
                    and sum(
                        1
                        for x in range(30, 190, 2)
                        if is_text(x, min(y + 3, h - 1))
                    )
                    >= 2)
            ):
                y += 1
            bands.append((y0, y - 1))
        else:
            y += 1
    for i, (y0, y1) in enumerate(bands):
        print(f'band {i}: y {y0}-{y1} center {(y0 + y1) // 2}')


if __name__ == '__main__':
    main()
