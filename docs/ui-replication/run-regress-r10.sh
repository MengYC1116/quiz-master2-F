#!/usr/bin/env bash
# R10 导航回归：点首页 → 学科管理（展开学科段）→ 设置（展开外观组）
# → 回首页，截图存入 docs/ui-replication/shots/r10/regress/，
# 确认两页进出链路与折叠展开正常。
#
# 用法：./run-regress-r10.sh
# 前置：已跑过 flutter build linux --release；DB 设置保持 dark/standard。
# 点击坐标按标准字号 1280×720 像素扫描实测（与 run-shots-r10.sh 一致：
# 导航“学科管理”Y 353、“设置”Y 667、学科段头 279、外观组头 245、
# 导航“首页”Y 100）。本回归不改库（只读跳转），结束时不碰数据库。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
OUT_DIR="$ROOT/docs/ui-replication/shots/r10/regress"
mkdir -p "$OUT_DIR"

DISPLAY_NUM=99
while [ -e "/tmp/.X${DISPLAY_NUM}-lock" ]; do DISPLAY_NUM=$((DISPLAY_NUM + 1)); done
DISPLAY=":$DISPLAY_NUM"
export DISPLAY

Xvfb "$DISPLAY" -screen 0 1280x720x24 >/dev/null 2>&1 &
XVFB_PID=$!
trap 'kill $APP_PID 2>/dev/null || true; kill $XVFB_PID 2>/dev/null || true' EXIT
sleep 2

"$BIN" >/tmp/quiz-master2-r10-regress.log 2>&1 &
APP_PID=$!
sleep 5

shot() { import -window root "$OUT_DIR/$1.png"; echo "截图已存：$OUT_DIR/$1.png"; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 2; }

shot regress-home             # 首页
click 100 353; shot regress-subjects    # 学科管理（默认全折）
click 700 279; shot regress-subjects-open  # 展开学科段
click 100 667; shot regress-settings    # 设置（默认全折）
click 700 245; shot regress-settings-open  # 展开外观组
click 100 100; shot regress-back-home  # 回首页

echo "回归完成"
