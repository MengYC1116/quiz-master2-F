#!/usr/bin/env bash
# R8 导航回归：点首页 → 复习列表 → 开始解决（进会话）→ 暂停（回列表，
# 出现恢复条）→ 回首页，截图存入 docs/ui-replication/shots/r8/regress/，
# 确认复习进出链路与暂停/恢复正常。
#
# 用法：./run-regress-r8.sh
# 前置：已跑过 flutter build linux --release；DB 设置保持 dark/standard。
# 点击坐标按标准字号 1280×720 像素扫描实测（与 run-shots-r8.sh 一致：
# 导航“复习”Y 271、“开始解决” (418,117)、会话“暂停” (865,135)、
# 导航“首页” (100,100)——目测估坐标会偏，校准须用像素扫描，见 R8-REPORT）。
# 注意：暂停会写 review_state（断点），脚本结束时清掉，恢复库原状。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
OUT_DIR="$ROOT/docs/ui-replication/shots/r8/regress"
DB="$HOME/.local/share/quiz-master2/quiz-master2.db"
mkdir -p "$OUT_DIR"

DISPLAY_NUM=99
while [ -e "/tmp/.X${DISPLAY_NUM}-lock" ]; do DISPLAY_NUM=$((DISPLAY_NUM + 1)); done
DISPLAY=":$DISPLAY_NUM"
export DISPLAY

Xvfb "$DISPLAY" -screen 0 1280x720x24 >/dev/null 2>&1 &
XVFB_PID=$!
trap 'kill $APP_PID 2>/dev/null || true; kill $XVFB_PID 2>/dev/null || true; sqlite3 "$DB" "DELETE FROM review_state;" 2>/dev/null || true' EXIT
sleep 2

"$BIN" >/tmp/quiz-master2-r8-regress.log 2>&1 &
APP_PID=$!
sleep 5

shot() { import -window root "$OUT_DIR/$1.png"; echo "截图已存：$OUT_DIR/$1.png"; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 2; }

shot regress-home             # 首页
click 100 271; shot regress-review-list    # 复习列表
click 418 117; shot regress-session        # 开始解决：会话第①步
click 865 135; shot regress-resume         # 暂停：回列表，出现恢复条
click 100 100; shot regress-back-home      # 回首页

sqlite3 "$DB" "DELETE FROM review_state;"
echo "回归完成，断点已清"
