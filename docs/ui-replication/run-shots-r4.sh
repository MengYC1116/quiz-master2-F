#!/usr/bin/env bash
# R4 收集中心截图脚手架：在 Xvfb 下以 1280×720 运行 quiz-master2（Linux Release
# 构建产物），按亮/深 × 标准/大/特大字号各截一张收集中心，另截空状态、
# 失败态、修框编辑器（正常 + 内框模式），存入 docs/ui-replication/shots/r4/。
#
# 用法：
#   ./run-shots-r4.sh                  # 全部截图
#   ./run-shots-r4.sh light standard   # 只截一组正常态
#
# 实现：主题与字号走应用设置（settings 表），截图前用 sqlite3 改库，
# 跑完恢复原值（改前先读出原值）；任务种子用 sqlite3 写入 collect_tasks
# 表（改前先整库备份到 /tmp，跑完用备份文件恢复）。不改代码、不加调试入口。
# 前置：已跑过 flutter build linux --release。
# 注意：Xvfb 下无系统主题设置，主题以 settings 表的 themeMode 为准。
# 导航收集中心点击坐标按标准字号 1280×720 实测（与 R2 回归脚本一致）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
OUT_DIR="$ROOT/docs/ui-replication/shots/r4"
DB="$HOME/.local/share/quiz-master2/quiz-master2.db"

[ -x "$BIN" ] || { echo "找不到可执行文件：$BIN"; echo "请先跑 flutter build linux --release"; exit 1; }
command -v Xvfb >/dev/null || { echo "未找到 Xvfb"; exit 1; }
command -v import >/dev/null || { echo "未找到 ImageMagick import"; exit 1; }
command -v sqlite3 >/dev/null || { echo "未找到 sqlite3"; exit 1; }
command -v xdotool >/dev/null || { echo "未找到 xdotool"; exit 1; }

mkdir -p "$OUT_DIR"

cp "$DB" /tmp/qm2-r4-orig.db
echo "原库已备份到 /tmp/qm2-r4-orig.db"

ORIG_THEME=$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='themeMode';")
ORIG_FONT=$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='fontSize';")
echo "原设置：themeMode=$ORIG_THEME fontSize=$ORIG_FONT（跑完恢复）"

restore() {
  cp /tmp/qm2-r4-orig.db "$DB"
  echo "库已恢复"
}
trap restore EXIT

# 6 态种子任务（显示顺序为 rowid DESC，即最后插入的最先显示）。
seed_six() {
  sqlite3 "$DB" <<'SQL'
DELETE FROM collect_tasks;
INSERT INTO collect_tasks (id, name, file_name, subject_id, status, progress, page_count, page, error)
  VALUES ('r4-failed', '政治模拟卷.pdf · 第1页 · 第1题', '政治模拟卷.pdf', 'politics', 'failed', 0, 1, 1, 'PDF 损坏打不开：无法读取任何页面');
INSERT INTO collect_tasks (id, name, file_name, subject_id, status, progress, page_count, page, error)
  VALUES ('r4-ready', '大学英语周测.pdf · 第1页 · 第1题', '大学英语周测.pdf', 'english', 'pendingOrganize', 100, 1, 1, NULL);
INSERT INTO collect_tasks (id, name, file_name, subject_id, status, progress, page_count, page, error)
  VALUES ('r4-boxing', '马原平时作业.pdf · 第1页 · 第1题', '马原平时作业.pdf', 'politics', 'boxing', 100, 1, 1, NULL);
INSERT INTO collect_tasks (id, name, file_name, subject_id, status, progress, page_count, page, error)
  VALUES ('r4-needbox', '高等数学作业 P42–43.jpg · 第1页 · 第1题', '高等数学作业 P42–43.jpg', 'math', 'needBox', 100, 3, 1, NULL);
INSERT INTO collect_tasks (id, name, file_name, subject_id, status, progress, page_count, page, error)
  VALUES ('r4-queued', '大学英语阅读专项.pdf · 第1页 · 第1题', '大学英语阅读专项.pdf', 'english', 'queued', 0, 1, 1, NULL);
INSERT INTO collect_tasks (id, name, file_name, subject_id, status, progress, page_count, page, error)
  VALUES ('r4-importing', '高等数学导数练习.pdf · 第1页 · 第1题', '高等数学导数练习.pdf', 'math', 'importing', 68, 2, 1, NULL);
SQL
}

# 单个待框选任务（3 页，供修框编辑器截图用）。
seed_editor() {
  sqlite3 "$DB" <<'SQL'
DELETE FROM collect_tasks;
INSERT INTO collect_tasks (id, name, file_name, subject_id, status, progress, page_count, page, error)
  VALUES ('r4-needbox', '高等数学作业 P42–43.jpg · 第1页 · 第1题', '高等数学作业 P42–43.jpg', 'math', 'needBox', 100, 3, 1, NULL);
SQL
}

launch() {
  local display_num=99
  while [ -e "/tmp/.X${display_num}-lock" ]; do display_num=$((display_num + 1)); done
  DISPLAY_NUM=$display_num
  DISPLAY=":$display_num"
  export DISPLAY
  Xvfb "$DISPLAY" -screen 0 1280x720x24 >/dev/null 2>&1 &
  XVFB_PID=$!
  sleep 2
  "$BIN" >/tmp/quiz-master2-r4-run.log 2>&1 &
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

# 正常态一张：进收集中心即截。
# 导航收集中心点击坐标随字号变：标准/大用 (100,139)，特大字号导航项变高，
# 收集中心移到约 y=170（实测：特大下 (100,139) 会点中首页）。
shot_normal() {
  local theme="$1" font="$2" name="$3"
  local nav_y=139
  if [ "$font" = "extraLarge" ]; then nav_y=170; fi
  seed_six
  set_theme_font "$theme" "$font"
  launch
  click 100 $nav_y
  shot "$name"
  stop_app
}

if [ $# -eq 2 ]; then
  shot_normal "$1" "$2" "collect-$1-$2"
  exit 0
fi

shot_normal light standard collect-light-standard
shot_normal light large collect-light-large
shot_normal light extraLarge collect-light-extraLarge
shot_normal dark standard collect-dark-standard
shot_normal dark large collect-dark-large
shot_normal dark extraLarge collect-dark-extraLarge

# 空状态：无任务。页面往下滚一段，露出空状态文案与 CTA 再截。
sqlite3 "$DB" "DELETE FROM collect_tasks;"
set_theme_font light standard
launch
click 100 139
xdotool mousemove 700 400 click 5 click 5 click 5; sleep 1
shot collect-empty-light-standard
stop_app
set_theme_font dark standard
launch
click 100 139
xdotool mousemove 700 400 click 5 click 5 click 5; sleep 1
shot collect-empty-dark-standard
stop_app

# 失败态：6 态种子，先把页面往下滚露出任务列表，再在列表区内往下滚，
# 露出最底下的失败行。
seed_six
set_theme_font light standard
launch
click 100 139
xdotool mousemove 700 400 click 5 click 5 click 5; sleep 1
xdotool mousemove 700 600 click 5 click 5 click 5 click 5 click 5 click 5 click 5; sleep 1
shot collect-failed-light-standard
stop_app

# 修框编辑器：单个 3 页待框选任务。
# 修框按钮坐标按标准字号实测（见 R4 报告 §4.3）：单任务行右侧 (820, 570)，
# 无需先滚页面；双击点为画布内题级框中心 (640, 355)。
seed_editor
set_theme_font light standard
launch
click 100 139
sleep 1
click 820 570
shot editor-light-standard
# 双击画布中央题级框进内框模式。
xdotool mousemove 640 355 click --repeat 2 --delay 120 1; sleep 2
shot editor-inner-light-standard
stop_app

seed_editor
set_theme_font dark standard
launch
click 100 139
sleep 1
click 820 570
shot editor-dark-standard
xdotool mousemove 640 355 click --repeat 2 --delay 120 1; sleep 2
shot editor-inner-dark-standard
stop_app

echo "全部截图完成，库已恢复（trap）"
