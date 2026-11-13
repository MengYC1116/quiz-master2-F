#!/usr/bin/env bash
# R2 外壳截图脚手架：在 Xvfb 下以 1280×720 运行 quiz-master2（Linux Release
# 构建产物），按亮/深 × 标准/大/特大字号各截一张首页外壳，存入
# docs/ui-replication/shots/r2/。
#
# 用法：
#   ./run-shots-r2.sh            # 6 张：light/dark × standard/large/extraLarge
#   ./run-shots-r2.sh light standard   # 只截一组
#
# 实现：主题与字号走应用设置（settings 表），截图前用 sqlite3 改库，
# 跑完恢复原值（改前先读出原值）。不改代码、不加调试入口。
# 前置：已跑过 flutter build linux --release。
# 注意：Xvfb 下无系统主题设置，主题以 settings 表的 themeMode 为准。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
OUT_DIR="$ROOT/docs/ui-replication/shots/r2"
DB="$HOME/.local/share/quiz-master2/quiz-master2.db"

[ -x "$BIN" ] || { echo "找不到可执行文件：$BIN"; echo "请先跑 flutter build linux --release"; exit 1; }
command -v Xvfb >/dev/null || { echo "未找到 Xvfb"; exit 1; }
command -v import >/dev/null || { echo "未找到 ImageMagick import"; exit 1; }
command -v sqlite3 >/dev/null || { echo "未找到 sqlite3"; exit 1; }

mkdir -p "$OUT_DIR"

ORIG_THEME=$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='themeMode';")
ORIG_FONT=$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='fontSize';")
echo "原设置：themeMode=$ORIG_THEME fontSize=$ORIG_FONT（跑完恢复）"

restore() {
  sqlite3 "$DB" "UPDATE settings SET value='$ORIG_THEME' WHERE key='themeMode'; UPDATE settings SET value='$ORIG_FONT' WHERE key='fontSize';"
}
trap restore EXIT

shot_one() {
  local theme="$1" font="$2" name="$3"
  sqlite3 "$DB" "UPDATE settings SET value='$theme' WHERE key='themeMode'; UPDATE settings SET value='$font' WHERE key='fontSize';"
  local display_num=99
  while [ -e "/tmp/.X${display_num}-lock" ]; do display_num=$((display_num + 1)); done
  local display=":$display_num"
  Xvfb "$display" -screen 0 1280x720x24 >/dev/null 2>&1 &
  local xvfb_pid=$!
  sleep 2
  DISPLAY="$display" "$BIN" >/tmp/quiz-master2-r2-run.log 2>&1 &
  local app_pid=$!
  sleep 5
  DISPLAY="$display" import -window root "$OUT_DIR/$name.png"
  kill $app_pid 2>/dev/null || true
  wait $app_pid 2>/dev/null || true
  kill $xvfb_pid 2>/dev/null || true
  echo "截图已存：$OUT_DIR/$name.png（$theme / $font）"
}

if [ $# -eq 2 ]; then
  shot_one "$1" "$2" "home-$1-$2"
else
  shot_one light standard home-light-standard
  shot_one light large home-light-large
  shot_one light extraLarge home-light-extraLarge
  shot_one dark standard home-dark-standard
  shot_one dark large home-dark-large
  shot_one dark extraLarge home-dark-extraLarge
fi
