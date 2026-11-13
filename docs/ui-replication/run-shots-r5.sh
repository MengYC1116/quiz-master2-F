#!/usr/bin/env bash
# R5 整理工作台截图脚手架：在 Xvfb 下以 1280×720 运行 quiz-master2（Linux Release
# 构建产物），按亮/深 × 标准/大/特大字号各截一张整理工作台，另截空状态
# （从未有题 / 队列已空）、队列弹窗、批量条、放大浮层，存入
# docs/ui-replication/shots/r5/。
#
# 用法：
#   ./run-shots-r5.sh                  # 全部截图
#   ./run-shots-r5.sh normal light standard   # 只截一组正常态
#   ./run-shots-r5.sh empty            # 只截 2 张空状态
#   ./run-shots-r5.sh queue            # 只截队列弹窗 + 批量条
#   ./run-shots-r5.sh zoom             # 只截放大浮层
#
# 实现：主题与字号走应用设置（settings 表）；空状态改库前整库备份到
# 工作区根目录 .qm2-r5-backup.db（不用 /tmp，R4 教训），跑完用备份
# 文件恢复并删除备份。不改代码、不加调试入口。
# 前置：已跑过 flutter build linux --release。
# 注意：Xvfb 下无系统主题设置，主题以 settings 表的 themeMode 为准。
# 导航整理工作台点击坐标按字号实测：标准 (100,182)、大 (100,199)、
# 特大 (100,230)；队列按钮 / 复选框 / 纸面图坐标见下文各段（标准字号
# 1280×720 实测）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
OUT_DIR="$ROOT/docs/ui-replication/shots/r5"
DB="$HOME/.local/share/quiz-master2/quiz-master2.db"
BACKUP="$ROOT/.qm2-r5-backup.db"

[ -x "$BIN" ] || { echo "找不到可执行文件：$BIN"; echo "请先跑 flutter build linux --release"; exit 1; }
command -v Xvfb >/dev/null || { echo "未找到 Xvfb"; exit 1; }
command -v import >/dev/null || { echo "未找到 ImageMagick import"; exit 1; }
command -v sqlite3 >/dev/null || { echo "未找到 sqlite3"; exit 1; }
command -v xdotool >/dev/null || { echo "未找到 xdotool"; exit 1; }

mkdir -p "$OUT_DIR"

cp "$DB" "$BACKUP"
echo "原库已备份到 $BACKUP"

ORIG_THEME=$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='themeMode';")
ORIG_FONT=$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='fontSize';")
echo "原设置：themeMode=$ORIG_THEME fontSize=$ORIG_FONT（跑完恢复）"

restore() {
  cp "$BACKUP" "$DB"
  rm -f "$BACKUP"
  echo "库已恢复，备份已删除"
}
trap restore EXIT

launch() {
  local display_num=99
  while [ -e "/tmp/.X${display_num}-lock" ]; do display_num=$((display_num + 1)); done
  DISPLAY_NUM=$display_num
  DISPLAY=":$display_num"
  export DISPLAY
  Xvfb "$DISPLAY" -screen 0 1280x720x24 >/dev/null 2>&1 &
  XVFB_PID=$!
  sleep 2
  "$BIN" >/tmp/quiz-master2-r5-run.log 2>&1 &
  APP_PID=$!
  sleep 5
}

stop_app() {
  kill $APP_PID 2>/dev/null || true
  wait $APP_PID 2>/dev/null || true
  kill $XVFB_PID 2>/dev/null || true
}

click() { xdotool mousemove "$1" "$2" click 1; sleep 2; }
shot() { import -window root "$OUT_DIR/$1.png"; echo "截图已存：$OUT_DIR/$1.png"; }

set_theme_font() {
  sqlite3 "$DB" "UPDATE settings SET value='$1' WHERE key='themeMode'; UPDATE settings SET value='$2' WHERE key='fontSize';"
}

# 整理工作台导航 Y（标准 182 / 大 199 / 特大 230，1280×720 实测）。
nav_organize_y() {
  case "$1" in
    large) echo 199 ;;
    extraLarge) echo 230 ;;
    *) echo 182 ;;
  esac
}

shot_normal() {
  local theme="$1" font="$2" name="$3"
  set_theme_font "$theme" "$font"
  launch
  click 100 "$(nav_organize_y "$font")"
  shot "$name"
  stop_app
}

shot_empty() {
  local mode="$1" theme="$2" name="$3"
  if [ "$mode" = "never" ]; then
    sqlite3 "$DB" "DELETE FROM questions;"
  else
    sqlite3 "$DB" "UPDATE questions SET is_organized=1;"
  fi
  set_theme_font "$theme" standard
  launch
  click 100 182
  shot "$name"
  stop_app
  cp "$BACKUP" "$DB"
}

shot_queue() {
  # 队列弹窗（深色标准）：点整理工作台 → 点左上角「队列」按钮（中心约 320,117）。
  set_theme_font dark standard
  launch
  click 100 182
  click 320 117
  shot organize-queue-dark-standard
  stop_app
}

shot_batch() {
  # 批量条（深色标准）：打开队列 → 勾第一行复选框 → 批量条出现。
  set_theme_font dark standard
  launch
  click 100 182
  click 320 117
  click 300 345
  shot organize-batch-dark-standard
  stop_app
}

shot_zoom() {
  # 放大浮层（亮色标准）：点整题纸面图中央。
  set_theme_font light standard
  launch
  click 100 182
  click 480 380
  shot organize-zoom-light-standard
  stop_app
}

if [ $# -eq 3 ] && [ "$1" = "normal" ]; then
  shot_normal "$2" "$3" "organize-$2-$3"
  exit 0
fi

if [ $# -eq 1 ] && [ "$1" = "empty" ]; then
  shot_empty never light organize-empty-never-light-standard
  shot_empty done dark organize-empty-done-dark-standard
  exit 0
fi

if [ $# -eq 1 ] && [ "$1" = "queue" ]; then
  shot_queue
  shot_batch
  exit 0
fi

if [ $# -eq 1 ] && [ "$1" = "zoom" ]; then
  shot_zoom
  exit 0
fi

shot_normal light standard organize-light-standard
shot_normal light large organize-light-large
shot_normal light extraLarge organize-light-extraLarge
shot_normal dark standard organize-dark-standard
shot_normal dark large organize-dark-large
shot_normal dark extraLarge organize-dark-extraLarge
shot_empty never light organize-empty-never-light-standard
shot_empty done dark organize-empty-done-dark-standard
shot_queue
shot_batch
shot_zoom

echo "全部截图完成，库已恢复（trap）"
