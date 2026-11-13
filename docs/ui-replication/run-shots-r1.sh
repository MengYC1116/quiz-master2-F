#!/usr/bin/env bash
# R1 截图脚手架：在 Xvfb 下以 1280×720 运行 quiz-master2（Linux Release 构建产物）
# 并对窗口截图，存入 docs/ui-replication/shots/r1/。
#
# 用法：
#   ./run-shots-r1.sh [shot-name] [wait-seconds]
#   ./run-shots-r1.sh home-dark        # 默认等 4 秒，存 shots/r1/home-dark.png
#   ./run-shots-r1.sh home-dark 6       # 等 6 秒再截
#
# 前置：已跑过 flutter build linux --release（产物在 build/linux/x64/release/bundle/）。
# 注意：
# - Xvfb 下无系统主题设置，应用默认走深色主题（与 R0 一致）；浅色截图需在应用内切主题
#   或在有主题设置的真机上另行截取，本脚本只负责“跑起来 + 截下来”。
# - 应用启动在 /home；切到其他页需人工在窗口里点，本脚本不做自动导航。
# - 截图工具为 ImageMagick 的 import（Xvfb 屏幕 :99）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
OUT_DIR="$ROOT/docs/ui-replication/shots/r1"
NAME="${1:-home-dark}"
WAIT="${2:-4}"
OUT="$OUT_DIR/$NAME.png"

[ -x "$BIN" ] || { echo "找不到可执行文件：$BIN"; echo "请先跑 flutter build linux --release"; exit 1; }
command -v Xvfb >/dev/null || { echo "未找到 Xvfb"; exit 1; }
command -v import >/dev/null || { echo "未找到 ImageMagick import"; exit 1; }

mkdir -p "$OUT_DIR"

# 若 :99 已被占用，换一个空闲显示号
DISPLAY_NUM=99
while [ -e "/tmp/.X${DISPLAY_NUM}-lock" ]; do DISPLAY_NUM=$((DISPLAY_NUM + 1)); done
DISPLAY=":$DISPLAY_NUM"

Xvfb "$DISPLAY" -screen 0 1280x720x24 >/dev/null 2>&1 &
XVFB_PID=$!
trap 'kill $XVFB_PID 2>/dev/null || true' EXIT
sleep 2

DISPLAY="$DISPLAY" "$BIN" >/tmp/quiz-master2-r1-run.log 2>&1 &
APP_PID=$!
trap 'kill $APP_PID 2>/dev/null || true; kill $XVFB_PID 2>/dev/null || true' EXIT

sleep "$WAIT"
DISPLAY="$DISPLAY" import -window root "$OUT"

kill $APP_PID 2>/dev/null || true
wait $APP_PID 2>/dev/null || true
echo "截图已存：$OUT"
