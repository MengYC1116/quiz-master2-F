#!/usr/bin/env bash
# R9 导航回归：点首页 → 学习报告 → 点弱点行（数学 · 计算错误）→
# 错题本（数学那本的目录页，错因筛好）→ 回首页，截图存入
# docs/ui-replication/shots/r9/regress/，确认报告进出链路与弱点跳转正常。
#
# 用法：./run-regress-r9.sh
# 前置：已跑过 flutter build linux --release；DB 设置保持 dark/standard。
# 点击坐标按标准字号 1280×720 像素扫描实测（与 run-shots-r9.sh 一致：
# 导航“学习报告”Y 312、弱点行 (700,407)、导航“首页” (100,100)——
# 目测估坐标会偏，校准须用像素扫描，见 R9-REPORT）。
# 注意：本回归不改库（只读跳转），结束时不碰数据库。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
OUT_DIR="$ROOT/docs/ui-replication/shots/r9/regress"
DB="$HOME/.local/share/quiz-master2/quiz-master2.db"
mkdir -p "$OUT_DIR"

DISPLAY_NUM=99
while [ -e "/tmp/.X${DISPLAY_NUM}-lock" ]; do DISPLAY_NUM=$((DISPLAY_NUM + 1)); done
DISPLAY=":$DISPLAY_NUM"
export DISPLAY

Xvfb "$DISPLAY" -screen 0 1280x720x24 >/dev/null 2>&1 &
XVFB_PID=$!
trap 'kill $APP_PID 2>/dev/null || true; kill $XVFB_PID 2>/dev/null || true' EXIT
sleep 2

"$BIN" >/tmp/quiz-master2-r9-regress.log 2>&1 &
APP_PID=$!
sleep 5

shot() { import -window root "$OUT_DIR/$1.png"; echo "截图已存：$OUT_DIR/$1.png"; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 2; }

shot regress-home             # 首页
click 100 312; shot regress-report    # 学习报告（本周）
click 700 407; shot regress-wrongbook # 点弱点行：数学错题本目录页
click 700 315; shot regress-wrongbook-list # 点“全部题目”：按错因筛好的列表
click 100 100; shot regress-back-home # 回首页

echo "回归完成"
