#!/usr/bin/env bash
# R8 复习页截图脚手架：在 Xvfb 下以 1280×720 运行 quiz-master2（Linux Release
# 构建产物），按亮/深 × 标准/大/特大字号截复习列表默认态，另截各状态
#（已治愈分组展开、恢复条、会话四步、放大浮层、总结、空态、错误态），
# 存入 docs/ui-replication/shots/r8/。
#
# 用法：
#   ./run-shots-r8.sh                  # 全部截图
#   ./run-shots-r8.sh probe            # 探针：首页 × 三档字号 + 列表 + 会话看错因（校准点击坐标用）
#   ./run-shots-r8.sh normal light standard   # 只截一组列表默认态
#   ./run-shots-r8.sh states           # 只截各状态
#
# 实现：主题与字号走应用设置（settings 表）；改库的状态改前整库备份到
# 工作区根目录 .qm2-r8-backup.db（不用 /tmp，R4 教训），跑完用备份
# 文件恢复并删除备份。不改代码、不加调试入口。
# 前置：已跑过 flutter build linux --release。
# 注意：Xvfb 下无系统主题设置，主题以 settings 表的 themeMode 为准。
# 点击坐标按字号实测（标准字号 1280×720）：导航复习见 nav_review_y；
# 其余见各函数内注释（R7 教训：缩放后截图里的目测坐标不可靠，必须用
# 像素扫描定位；本轮探针图已按此法校准，见 R8-REPORT）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
OUT_DIR="$ROOT/docs/ui-replication/shots/r8"
DB="$HOME/.local/share/quiz-master2/quiz-master2.db"
BACKUP="$ROOT/.qm2-r8-backup.db"

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
  "$BIN" >/tmp/quiz-master2-r8-run.log 2>&1 &
  APP_PID=$!
  sleep 5
}

stop_app() {
  kill $APP_PID 2>/dev/null || true
  wait $APP_PID 2>/dev/null || true
  kill $XVFB_PID 2>/dev/null || true
}

click() { xdotool mousemove "$1" "$2" click 1; sleep 2; }
key() { xdotool key "$1"; sleep 2; }
type_text() { LC_ALL=C.UTF-8 xdotool type --delay 60 "$1"; sleep 2; }
shot() { import -window root "$OUT_DIR/$1.png"; echo "截图已存：$OUT_DIR/$1.png"; }
scroll_down() { xdotool mousemove 640 360 click 5; sleep 1; }
scroll_down_n() { for _ in $(seq "$1"); do scroll_down; done; }

set_theme_font() {
  sqlite3 "$DB" "UPDATE settings SET value='$1' WHERE key='themeMode'; UPDATE settings SET value='$2' WHERE key='fontSize';"
}

# 导航“复习”Y（1280×720 像素扫描实测，探针校准；见 R8-REPORT）。
nav_review_y() {
  case "$1" in
    large) echo 294 ;;
    extraLarge) echo 334 ;;
    *) echo 271 ;;
  esac
}

go_review() { click 100 "$(nav_review_y "$1")"; }

shot_review() {
  local theme="$1" font="$2" name="$3"
  set_theme_font "$theme" "$font"
  launch
  go_review "$font"
  shot "$name"
  stop_app
}

shot_probe() {
  # 首页 × 三档字号（校准导航“复习”Y 用）。
  for font in standard large extraLarge; do
    set_theme_font dark "$font"
    launch
    shot "probe-home-dark-$font"
    stop_app
  done
  # 列表 + 会话看错因（标准档，校准列表/会话按钮坐标用）。
  set_theme_font dark standard
  launch
  go_review standard
  shot probe-list-dark-standard
  click 418 117
  shot probe-session-recall-dark-standard
  stop_app
}

if [ $# -eq 1 ] && [ "$1" = "probe" ]; then
  shot_probe
  exit 0
fi

if [ $# -eq 3 ] && [ "$1" = "normal" ]; then
  shot_review "$2" "$3" "review-$2-$3"
  exit 0
fi

shot_states() {
  # ---- 已治愈分组展开（亮色标准）：先把 q-eng-1 的复查日推到未来，
  # 使 英语|概念不清 进已治愈组；拍完恢复库。
  sqlite3 "$DB" "UPDATE cause_records SET recheck_date = 1795238400000 WHERE question_id = 'q-eng-1';"
  set_theme_font light standard
  launch
  go_review standard
  shot review-cured-collapsed-light-standard
  click 700 538
  shot review-cured-expanded-light-standard
  stop_app
  cp "$BACKUP" "$DB"

  # ---- 恢复条（亮色标准）：先写一条断点（q-math-3 在队首）。
  sqlite3 "$DB" "INSERT INTO review_state (id, queue, position, updated_at) VALUES (1, 'q-math-3|计算错误,q-math-1|概念不清', 0, 1794000000000);"
  set_theme_font light standard
  launch
  go_review standard
  shot review-resume-light-standard
  stop_app
  cp "$BACKUP" "$DB"

  # ---- 空态（亮色标准）：全部取消加入复习。
  sqlite3 "$DB" "UPDATE questions SET review_joined = 0;"
  set_theme_font light standard
  launch
  go_review standard
  shot review-empty-light-standard
  stop_app
  cp "$BACKUP" "$DB"

  # ---- 会话四步 + 放大浮层 + 总结（深色标准；会改 cause_records，
  # 拍完靠 trap 恢复）。三块：q-math-1 → q-math-3 → q-eng-1。
  set_theme_font dark standard
  launch
  go_review standard
  click 418 117
  shot review-session-recall-dark-standard
  click 748 355
  shot review-zoom-dark-standard
  key Escape
  click 691 581
  shot review-session-remedy-dark-standard
  click 696 497
  shot review-session-redo-dark-standard
  click 748 520
  shot review-session-redo-shown-dark-standard
  click 691 593
  shot review-session-check-dark-standard
  click 421 414
  sleep 1
  click 748 505
  # 第 2 块 q-math-3：同一套坐标。
  click 691 581
  click 696 497
  click 748 520
  click 691 593
  click 421 414
  sleep 1
  click 748 505
  # 第 3 块 q-eng-1（复查项）：同一套坐标，最后是“看总结”。
  click 691 581
  click 696 497
  click 748 520
  click 691 593
  click 421 414
  sleep 1
  click 748 505
  shot review-summary-dark-standard
  stop_app
}

if [ $# -eq 1 ] && [ "$1" = "states" ]; then
  shot_states
  exit 0
fi

shot_review light standard review-light-standard
shot_review light large review-light-large
shot_review light extraLarge review-light-extraLarge
shot_review dark standard review-dark-standard
shot_review dark large review-dark-large
shot_review dark extraLarge review-dark-extraLarge
shot_states

echo "全部截图完成，库已恢复（trap）"
