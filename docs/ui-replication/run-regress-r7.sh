#!/usr/bin/env bash
# R7 导航回归：点首页 → 错题本（书架）→ 数学书（目录）→ 全部题目（列表）
# → 第一道题（详情页）→ 返回错题本（列表）→ 回首页，截图存入
# docs/ui-replication/shots/r7/regress/，确认详情页进出链路与返回来源正常。
#
# 用法：./run-regress-r7.sh
# 前置：已跑过 flutter build linux --release；DB 设置保持 dark/standard。
# 点击坐标按标准字号 1280×720 实测（与 run-shots-r7.sh 一致；详情页返回按钮
# 像素实测中心约 (190,45)，编辑按钮约 (903,45)，删除按钮滚后约 (785,665)——
# 目测估坐标会偏 5~85px，校准须用像素扫描，见 R7-REPORT 差异修复记录）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
OUT_DIR="$ROOT/docs/ui-replication/shots/r7/regress"
mkdir -p "$OUT_DIR"

DISPLAY_NUM=99
while [ -e "/tmp/.X${DISPLAY_NUM}-lock" ]; do DISPLAY_NUM=$((DISPLAY_NUM + 1)); done
DISPLAY=":$DISPLAY_NUM"
export DISPLAY

Xvfb "$DISPLAY" -screen 0 1280x720x24 >/dev/null 2>&1 &
XVFB_PID=$!
trap 'kill $APP_PID 2>/dev/null || true; kill $XVFB_PID 2>/dev/null || true' EXIT
sleep 2

"$BIN" >/tmp/quiz-master2-r7-regress.log 2>&1 &
APP_PID=$!
sleep 5

shot() { import -window root "$OUT_DIR/$1.png"; echo "截图已存：$OUT_DIR/$1.png"; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 2; }

shot nav-home             # 首页
click 100 225; shot nav-wrongbook-shelf    # 错题本书架
click 430 400; shot nav-wrongbook-directory # 数学书目录
click 500 310; shot nav-wrongbook-list      # 全部题目列表
click 640 300; shot nav-detail             # 第一道题：详情页
click 190 45;  shot nav-back-list          # 返回错题本（列表）
click 100 97;  shot nav-back-home          # 回首页
