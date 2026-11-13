#!/usr/bin/env bash
# R2 九页回归：在 Xvfb 1280×720 下逐个点导航（九页 + 折叠），截图存入
# docs/ui-replication/shots/r2/regress/，供人工确认每页都可进入、
# 导航切换与角标显示正常。
#
# 用法：./run-regress-r2.sh
# 前置：已跑过 flutter build linux --release；DB 设置保持 dark/standard
#（脚本不改设置）。导航项点击坐标按标准字号 1280×720 实测（见 R2 报告）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
OUT_DIR="$ROOT/docs/ui-replication/shots/r2/regress"
mkdir -p "$OUT_DIR"

DISPLAY_NUM=99
while [ -e "/tmp/.X${DISPLAY_NUM}-lock" ]; do DISPLAY_NUM=$((DISPLAY_NUM + 1)); done
DISPLAY=":$DISPLAY_NUM"
export DISPLAY

Xvfb "$DISPLAY" -screen 0 1280x720x24 >/dev/null 2>&1 &
XVFB_PID=$!
trap 'kill $APP_PID 2>/dev/null || true; kill $XVFB_PID 2>/dev/null || true' EXIT
sleep 2

"$BIN" >/tmp/quiz-master2-r2-regress.log 2>&1 &
APP_PID=$!
sleep 5

shot() { import -window root "$OUT_DIR/$1.png"; echo "截图已存：$OUT_DIR/$1.png"; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 2; }

# 导航项中心坐标（标准字号，x≈100；设置按钮 x≈108，y≈659）
click 100 139; shot page-collect      # 收集中心
click 100 182; shot page-organize     # 整理工作台
click 100 224; shot page-wrongbook    # 错题本
click 100 266; shot page-review       # 复习
click 100 309; shot page-report       # 学习报告
click 100 351; shot page-subjects     # 学科管理
click 108 659; shot page-settings     # 设置（底部按钮）
# 折叠导航：品牌行箭头（x≈215，y≈40）
click 188 32; shot nav-collapsed
# 再展开：折叠态箭头在顶部居中（x≈32，y≈40），回首页
click 32 32; sleep 1
click 100 97; shot nav-expanded-home # 回首页（展开态）
