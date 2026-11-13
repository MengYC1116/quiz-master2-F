#!/usr/bin/env bash
# S8 B2 截图脚手架：在 Xvfb 下以 1280×720 运行 quiz-master2（Linux Release
# 构建产物），截首页 + 导航速览（同一张整窗截图同时覆盖两者）：
#   home-4-dark-standard  第 4 科（化学）加入后，深色
#   home-4-light-standard 第 4 科加入后，亮色
#   home-6-dark-standard  第 6 科（地理）加入后，深色
#   home-6-light-standard 第 6 科加入后，亮色
# 存入 docs/ui-replication/shots/s8b2/。
#
# 临时改库（拍完用备份恢复）：
#   subjects += 化学 subject-chem 紫 0xFF7C5CFC（轮换表第 4 位）
#   subjects += 历史 subject-hist 橙 0xFFF08A1D（轮换表第 5 位）
#   subjects += 地理 subject-geo 蓝 0xFF2E7CF6（轮换表绕回首位，与
#     学科管理页新建第 6 科的实际取色一致）
#   questions += q-chem-1（已整理、已加入复习）+ 1 条 pending 错因
#     -> 化学格应显示“要复习 1 道 · 待整理 1 道”
#   questions += q-chem-2（未整理）-> 待整理 1
# 预期：
#   4 科时首页 1 + 4 格、导航 4 行；6 科时首页 1 + 6 格（分两行）、
#   导航只显示前 5 行（地理不出现）。
#
# 用法：
#   ./run-shots-s8b2.sh probe    # 只截一张探针图（4 科深色）
#   ./run-shots-s8b2.sh          # 四张全截
#
# 实现：改库前整库备份到工作区根目录 .qm2-s8b2-backup.db，跑完用备份
# 文件恢复并删除备份。主题走 settings 表（原库是 dark/standard）。
# 前置：已跑过 flutter build linux --release。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
OUT_DIR="$ROOT/docs/ui-replication/shots/s8b2"
DB="$HOME/.local/share/quiz-master2/quiz-master2.db"
BACKUP="$ROOT/.qm2-s8b2-backup.db"

[ -x "$BIN" ] || { echo "找不到可执行文件：$BIN"; echo "请先跑 flutter build linux --release"; exit 1; }
command -v Xvfb >/dev/null || { echo "未找到 Xvfb"; exit 1; }
command -v import >/dev/null || { echo "未找到 ImageMagick import"; exit 1; }
command -v sqlite3 >/dev/null || { echo "未找到 sqlite3"; exit 1; }

mkdir -p "$OUT_DIR"

cp "$DB" "$BACKUP"
echo "原库已备份到 $BACKUP"

restore() {
  pkill -x quiz_master2 2>/dev/null || true
  sleep 1
  cp "$BACKUP" "$DB"
  rm -f "$BACKUP"
  echo "库已恢复，备份已删除"
  sqlite3 "$DB" "SELECT 'subjects=' || COUNT(*) FROM subjects; SELECT 'questions=' || COUNT(*) FROM questions; SELECT key || '=' || value FROM settings WHERE key='themeMode';"
}
trap restore EXIT

NOW_MS=$(( $(date +%s) * 1000 ))
PURPLE=$((16#FF7C5CFC))
ORANGE=$((16#FFF08A1D))
BLUE=$((16#FF2E7CF6))

add_chem() {
  sqlite3 "$DB" \
    "INSERT INTO subjects(id,name,color,cover_style,cover_color) VALUES('subject-chem','化学',$PURPLE,'plain','grey');
     INSERT INTO questions(id,title,subject_id,folder_ids,exam_id,knowledge_ids,error_types,custom_error_types,tags,answer,explanation,notes,review_count,is_organized,is_demo,is_favorite,is_archived,review_joined,created_at,slice_kind,slice_text) VALUES('q-chem-1','化学平衡移动', 'subject-chem','','', '','概念不清','','','', '', '',0,1,0,0,0,1,$NOW_MS,'material','');
     INSERT INTO questions(id,title,subject_id,folder_ids,exam_id,knowledge_ids,error_types,custom_error_types,tags,answer,explanation,notes,review_count,is_organized,is_demo,is_favorite,is_archived,review_joined,created_at,slice_kind,slice_text) VALUES('q-chem-2','氧化还原配平','subject-chem','','','','','','','', '', '',0,0,0,0,0,0,$NOW_MS,'material','');
     INSERT INTO cause_records(question_id,cause,subject_id,status,solved_count,last_check,recheck_date,remedy_history,joined_at) VALUES('q-chem-1','概念不清','subject-chem','pending',0,NULL,NULL,'',$NOW_MS);"
  echo "已加第 4 科化学 + 2 道题（1 道待复习、1 道待整理）"
  sqlite3 "$DB" "SELECT id, name FROM subjects ORDER BY rowid;"
}

add_hist_geo() {
  sqlite3 "$DB" \
    "INSERT INTO subjects(id,name,color,cover_style,cover_color) VALUES('subject-hist','历史',$ORANGE,'plain','grey');
     INSERT INTO subjects(id,name,color,cover_style,cover_color) VALUES('subject-geo','地理',$BLUE,'plain','grey');"
  echo "已加第 5 科历史、第 6 科地理（无题）"
  sqlite3 "$DB" "SELECT id, name FROM subjects ORDER BY rowid;"
}

set_theme() { # light | dark
  sqlite3 "$DB" "UPDATE settings SET value='$1' WHERE key='themeMode';"
  echo "主题已切为 $1"
}

launch() {
  local display_num=99
  while [ -e "/tmp/.X${display_num}-lock" ]; do display_num=$((display_num + 1)); done
  DISPLAY=":$display_num"
  export DISPLAY
  Xvfb "$DISPLAY" -screen 0 1280x720x24 >/dev/null 2>&1 &
  XVFB_PID=$!
  sleep 2
  "$BIN" >/tmp/quiz-master2-s8b2-run.log 2>&1 &
  sleep 5
}

stop_app() {
  pkill -x quiz_master2 2>/dev/null || true
  sleep 1
  kill $XVFB_PID 2>/dev/null || true
}

shot() { import -window root "$OUT_DIR/$1.png"; echo "截图已存：$OUT_DIR/$1.png"; }

if [ $# -eq 1 ] && [ "$1" = "probe" ]; then
  add_chem
  launch
  shot probe-home-4-dark
  stop_app
  exit 0
fi

add_chem
launch
shot home-4-dark-standard
stop_app

set_theme light
launch
shot home-4-light-standard
stop_app

set_theme dark
add_hist_geo
launch
shot home-6-dark-standard
stop_app

set_theme light
launch
shot home-6-light-standard
stop_app

echo "四张截图完成，库已恢复（trap）"
