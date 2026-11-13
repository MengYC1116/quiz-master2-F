#!/usr/bin/env python3
"""R6 并排对照合成：把 HTML 原型截图（上）与 Flutter 截图（下）竖排拼成一张，
中间加标签条。用法：
  make-compare-r6.py <html.png> <flutter.png> <out.png> <html标签> <flutter标签>
标签用 PIL 默认字体绘制（仅作示意标记，不追求排版）。
"""
import sys

from PIL import Image, ImageDraw

HTML_PNG, FLUTTER_PNG, OUT, HTML_LABEL, FLUTTER_LABEL = sys.argv[1:6]
BAR = 34


def label_bar(w, text):
    bar = Image.new("RGB", (w, BAR), (23, 35, 59))
    d = ImageDraw.Draw(bar)
    d.text((12, 10), text, fill=(255, 255, 255))
    return bar


html = Image.open(HTML_PNG).convert("RGB")
flutter = Image.open(FLUTTER_PNG).convert("RGB")
w = max(html.width, flutter.width)


def fit(im):
    if im.width == w:
        return im
    return im.resize((w, int(im.height * w / im.width)))


out = Image.new(
    "RGB", (w, BAR + fit(html).height + BAR + fit(flutter).height), (255, 255, 255)
)
y = 0
out.paste(label_bar(w, HTML_LABEL), (0, y))
y += BAR
out.paste(fit(html), (0, y))
y += fit(html).height
out.paste(label_bar(w, FLUTTER_LABEL), (0, y))
y += BAR
out.paste(fit(flutter), (0, y))
out.save(OUT)
print(f"saved {OUT} ({out.width}x{out.height})")
