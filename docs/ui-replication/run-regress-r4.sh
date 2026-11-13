#!/usr/bin/env bash
# R4 导航回归：点收集中心 → 整理工作台 → 回首页，截图存入
# docs/ui-replication/shots/r4/regress/，确认导航切换与新收集中心正常。
#
# 用法：./run-regress-r4.sh
# 前置：已跑过 flutter build linux --release；DB 设置保持 dark/standard。
# 导航项点击坐标按标准字号 1280×720 实测（与 R2 回归脚本一致）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
OUT_DIR="$ROOT/docs/ui-replication/shots/r4/regress"
mkdir -p "$OUT_DIR"

DISPLAY_NUM=99
while [ -e "/tmp/.X${DISPLAY_NUM}-lock" ]; do DISPLAY_NUM=$((DISPLAY_NUM + 1)); done
DISPLAY=":$DISPLAY_NUM"
export DISPLAY

Xvfb "$DISPLAY" -screen 0 1280x720x24 >/dev/null 2>&1 &
XVFB_PID=$!
trap 'kill $APP_PID 2>/dev/null || true; kill $XVFB_PID 2>/dev/null || true' EXIT
sleep 2

"$BIN" >/tmp/quiz-master2-r4-regress.log 2>&1 &
APP_PID=$!
sleep 5

shot() { import -window root "$OUT_DIR/$1.png"; echo "截图已存：$OUT_DIR/$1.png"; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 2; }

click 100 139; shot nav-collect    # 收集中心（新版）
click 100 182; shot nav-organize   # 整理工作台
click 100 97;  shot nav-back-home  # 回首页
