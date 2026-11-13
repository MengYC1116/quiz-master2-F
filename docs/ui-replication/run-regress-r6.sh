#!/usr/bin/env bash
# R6 导航回归：点首页 → 错题本（书架）→ 数学书（目录）→ 全部题目（列表）
# → 回首页，截图存入 docs/ui-replication/shots/r6/regress/，确认新错题本
# 三层链路与导航切换正常。
#
# 用法：./run-regress-r6.sh
# 前置：已跑过 flutter build linux --release；DB 设置保持 dark/standard。
# 点击坐标按标准字号 1280×720 实测（与 run-shots-r6.sh 一致）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
OUT_DIR="$ROOT/docs/ui-replication/shots/r6/regress"
mkdir -p "$OUT_DIR"

DISPLAY_NUM=99
while [ -e "/tmp/.X${DISPLAY_NUM}-lock" ]; do DISPLAY_NUM=$((DISPLAY_NUM + 1)); done
DISPLAY=":$DISPLAY_NUM"
export DISPLAY

Xvfb "$DISPLAY" -screen 0 1280x720x24 >/dev/null 2>&1 &
XVFB_PID=$!
trap 'kill $APP_PID 2>/dev/null || true; kill $XVFB_PID 2>/dev/null || true' EXIT
sleep 2

"$BIN" >/tmp/quiz-master2-r6-regress.log 2>&1 &
APP_PID=$!
sleep 5

shot() { import -window root "$OUT_DIR/$1.png"; echo "截图已存：$OUT_DIR/$1.png"; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 2; }

shot nav-home             # 首页
click 100 225; shot nav-wrongbook-shelf    # 错题本书架
click 430 400; shot nav-wrongbook-directory # 数学书目录
click 500 310; shot nav-wrongbook-list      # 全部题目列表
click 100 97;  shot nav-back-home          # 回首页
