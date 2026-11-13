#!/usr/bin/env bash
# R9 学习报告页截图脚手架：在 Xvfb 下以 1280×720 运行 quiz-master2（Linux Release
# 构建产物），按亮/深 × 标准/大/特大字号截报告默认态（本周），另截各状态
#（本月展开、空态、复查通过率、点弱点行进错题本），存入
# docs/ui-replication/shots/r9/。
#
# 用法：
#   ./run-shots-r9.sh                  # 全部截图
#   ./run-shots-r9.sh probe            # 探针：首页 × 三档字号（校准导航“学习报告”Y 用）
#   ./run-shots-r9.sh normal light standard   # 只截一组报告默认态
#   ./run-shots-r9.sh states           # 只截各状态
#
# 实现：主题与字号走应用设置（settings 表）；改库的状态改前整库备份到
# 工作区根目录 .qm2-r9-backup.db（不用 /tmp，R4 教训），跑完用备份
# 文件恢复并删除备份。不改代码、不加调试入口。
# 前置：已跑过 flutter build linux --release。
# 注意：Xvfb 下无系统主题设置，主题以 settings 表的 themeMode 为准。
# 点击坐标按字号实测（标准字号 1280×720）：导航“学习报告”见 nav_report_y；
# 其余见各函数内注释（R7/R8 教训：缩放后截图里的目测坐标不可靠，必须用
# 像素扫描定位；本轮探针图已按此法校准，见 R9-REPORT）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
OUT_DIR="$ROOT/docs/ui-replication/shots/r9"
DB="$HOME/.local/share/quiz-master2/quiz-master2.db"
BACKUP="$ROOT/.qm2-r9-backup.db"

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
  "$BIN" >/tmp/quiz-master2-r9-run.log 2>&1 &
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

# 导航“学习报告”Y（1280×720 像素扫描实测，探针校准；见 R9-REPORT）。
# 扫描法：scan-nav.py 找导航文字带；标准档带 8 中心 312、大档带 7
# 中心 341、特大档带 7 中心 389（复习 Y 与 R8 的 271/294/334 一致）。
nav_report_y() {
  case "$1" in
    large) echo 341 ;;
    extraLarge) echo 389 ;;
    *) echo 312 ;;
  esac
}

go_report() { click 100 "$(nav_report_y "$1")"; }

shot_report() {
  local theme="$1" font="$2" name="$3"
  set_theme_font "$theme" "$font"
  launch
  go_report "$font"
  shot "$name"
  stop_app
}

shot_probe() {
  # 首页 × 三档字号（校准导航“学习报告”Y 用）。
  for font in standard large extraLarge; do
    set_theme_font dark "$font"
    launch
    shot "probe-home-dark-$font"
    stop_app
  done
  # 报告默认态（标准档，校准页内控件坐标用）。
  set_theme_font dark standard
  launch
  go_report standard
  shot probe-report-dark-standard
  stop_app
}

if [ $# -eq 1 ] && [ "$1" = "probe" ]; then
  shot_probe
  exit 0
fi

if [ $# -eq 3 ] && [ "$1" = "normal" ]; then
  shot_report "$2" "$3" "report-$2-$3"
  exit 0
fi

shot_states() {
  # ---- 本月 + 两组都展开（亮色标准）：点“本月”，滚到“看更多”再点两列的。
  set_theme_font light standard
  launch
  go_report standard
  click 344 88
  shot report-month-light-standard
  # “看更多”在首屏外：向下滚 4 次（每滚约 56px）再点，坐标像素扫描实测。
  for _ in 1 2 3 4; do xdotool mousemove 640 360 click 5; sleep 1; done
  click 318 508
  click 837 513
  shot report-month-expanded-light-standard
  stop_app

  # ---- 空态（亮色标准）：清空错因记录，拍完恢复库。
  sqlite3 "$DB" "DELETE FROM cause_records;"
  set_theme_font light standard
  launch
  go_report standard
  shot report-empty-light-standard
  stop_app
  cp "$BACKUP" "$DB"

  # ---- 复查通过率（亮色标准）：临时插 3 条本周内自查记录（2 通过 1 未过），
  # 拍完恢复库。reviewed_at 取 2026-11-12 10:00（本周内）。
  local rate_ts
  rate_ts=$(( $(date -d '2026-11-12 10:00:00' +%s) * 1000 ))
  sqlite3 "$DB" "INSERT INTO review_history (question_id, result, reviewed_at) VALUES ('q-math-1', 'solved', $rate_ts), ('q-math-3', 'solved', $rate_ts), ('q-eng-1', 'unsolved', $rate_ts);"
  set_theme_font light standard
  launch
  go_report standard
  shot report-rate-light-standard
  stop_app
  cp "$BACKUP" "$DB"

  # ---- 点弱点行进错题本（深色标准）：点本周第一行（数学 · 计算错误），
  # 应打开数学那本的目录页并按错因筛好。
  set_theme_font dark standard
  launch
  go_report standard
  click 700 407
  shot report-row-to-wrongbook-dark-standard
  stop_app
}

if [ $# -eq 1 ] && [ "$1" = "states" ]; then
  shot_states
  exit 0
fi

shot_report light standard report-light-standard
shot_report light large report-light-large
shot_report light extraLarge report-light-extraLarge
shot_report dark standard report-dark-standard
shot_report dark large report-dark-large
shot_report dark extraLarge report-dark-extraLarge
shot_states

echo "全部截图完成，库已恢复（trap）"
