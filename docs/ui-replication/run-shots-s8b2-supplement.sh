#!/usr/bin/env bash
# S8 B2 补充验证：§2 的 8 处未同步点全部改成读库 subjects。
#   probe 模式：加化学 + 2 道题，截首页/收集/复习/错题本（书架）/
#     学习报告五张探针图（用来量下拉框、书架、目录、切换按钮坐标），
#     随后恢复库。
#   完整模式：同上加库后做交互验证——
#     1) 收集中心：点导入学科下拉（菜单里应有化学）→ 键盘选化学 →
#        下拉显示化学；
#     2) 复习：点学科筛选下拉（菜单里应有化学）→ 键盘选化学 →
#        列表只剩化学组；
#     3) 错题本：进化学书 → 全部题目 → 切紧凑列表 → 化学行紫名；
#     4) 学习报告：分布行与弱点行出现化学（弱点行紫名）。
#     亮/深各跑一遍（第 2 个参数 light | dark，默认 dark）。
#   改库前整库备份到工作区根目录 .qm2-s8b2sup-backup.db，跑完恢复并
#   删除备份；恢复态按任务要求：9 道题、3 学科、深色、启动页 home。
#   杀应用用 pkill -x quiz_master2。
#
# 用法：
#   ./run-shots-s8b2-supplement.sh probe [light|dark]
#   ./run-shots-s8b2-supplement.sh [light|dark]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
OUT_DIR="$ROOT/docs/ui-replication/shots/s8b2-supplement"
DB="$HOME/.local/share/quiz-master2/quiz-master2.db"
BACKUP="$ROOT/.qm2-s8b2sup-backup.db"
THEME=dark
MODE=full
for a in "$@"; do
  case "$a" in
    probe) MODE=probe ;;
    light|dark) THEME="$a" ;;
    *) echo "未知参数：$a（可用 probe / light / dark）"; exit 1 ;;
  esac
done

[ -x "$BIN" ] || { echo "找不到可执行文件：$BIN"; echo "请先跑 flutter build linux --release"; exit 1; }
for c in Xvfb import xdotool sqlite3; do
  command -v "$c" >/dev/null || { echo "未找到 $c"; exit 1; }
done

mkdir -p "$OUT_DIR"

# 左导航行中心（1280x720，B3 探针图上量得）。
NAV_X=100
NAV_COLLECT_Y=129
NAV_WRONGBOOK_Y=215
NAV_REVIEW_Y=257
NAV_REPORT_Y=300

# 以下坐标由 probe 图量得（见 S8B2 补充报告 §5）。
# 收集下拉框（请选择学科）中心 / 菜单里化学项。
COLLECT_DROPDOWN_X=750
COLLECT_DROPDOWN_Y=126
COLLECT_CHEM_X=340
COLLECT_CHEM_Y=272
# 复习学科筛选下拉框中心 / 菜单里化学项。
REVIEW_FILTER_X=470
REVIEW_FILTER_Y=208
REVIEW_CHEM_X=430
REVIEW_CHEM_Y=401
# 书架化学书中心 / 目录页“全部题目”行 / 列表页“紧凑列表”切换。
SHELF_CHEM_X=1140
SHELF_CHEM_Y=345
DIR_ALL_X=350
DIR_ALL_Y=195
COMPACT_TOGGLE_X=1035
COMPACT_TOGGLE_Y=162

cp "$DB" "$BACKUP"
echo "原库已备份到 $BACKUP"

restore() {
  pkill -x quiz_master2 2>/dev/null || true
  sleep 1
  cp "$BACKUP" "$DB"
  rm -f "$BACKUP"
  sqlite3 "$DB" "INSERT OR REPLACE INTO settings(key,value) VALUES('themeMode','dark'); INSERT OR REPLACE INTO settings(key,value) VALUES('startupPage','home'); INSERT OR REPLACE INTO settings(key,value) VALUES('lastRoute','/home');"
  echo "库已恢复，备份已删除"
  sqlite3 "$DB" "SELECT 'subjects=' || COUNT(*) FROM subjects; SELECT 'questions=' || COUNT(*) FROM questions; SELECT key || '=' || value FROM settings WHERE key IN ('themeMode','startupPage','lastRoute');"
}
trap restore EXIT

setup_db() {
  local now_ms=$(( $(date +%s) * 1000 ))
  local purple=$((16#FF7C5CFC))
  sqlite3 "$DB" \
    "INSERT INTO subjects(id,name,color,cover_style,cover_color) VALUES('subject-chem','化学',$purple,'plain','grey');
     INSERT INTO questions(id,title,subject_id,folder_ids,exam_id,knowledge_ids,error_types,custom_error_types,tags,answer,explanation,notes,review_count,is_organized,is_demo,is_favorite,is_archived,review_joined,created_at,slice_kind,slice_text) VALUES('q-chem-1','化学平衡移动', 'subject-chem','','', '','概念不清','','','', '', '',0,1,0,0,0,1,$now_ms,'material','');
     INSERT INTO questions(id,title,subject_id,folder_ids,exam_id,knowledge_ids,error_types,custom_error_types,tags,answer,explanation,notes,review_count,is_organized,is_demo,is_favorite,is_archived,review_joined,created_at,slice_kind,slice_text) VALUES('q-chem-2','氧化还原配平','subject-chem','','','','','','','', '', '',0,0,0,0,0,0,$now_ms,'material','');
     INSERT INTO cause_records(question_id,cause,subject_id,status,solved_count,last_check,recheck_date,remedy_history,joined_at) VALUES('q-chem-1','概念不清','subject-chem','pending',0,NULL,NULL,'',$now_ms);
     INSERT OR REPLACE INTO settings(key,value) VALUES('themeMode','$THEME');
     INSERT OR REPLACE INTO settings(key,value) VALUES('startupPage','home');"
  echo "已加化学 + 2 道题（q-chem-1 待复习、q-chem-2 待整理），主题=$THEME"
  sqlite3 "$DB" "SELECT id, name FROM subjects ORDER BY rowid;"
}

launch() {
  local display_num=99
  while [ -e "/tmp/.X${display_num}-lock" ]; do display_num=$((display_num + 1)); done
  DISPLAY=":$display_num"
  export DISPLAY
  Xvfb "$DISPLAY" -screen 0 1280x720x24 >/dev/null 2>&1 &
  XVFB_PID=$!
  sleep 2
  "$BIN" >/tmp/quiz-master2-s8b2sup-run.log 2>&1 &
  sleep 5
}

stop_app() {
  pkill -x quiz_master2 2>/dev/null || true
  sleep 1
  kill $XVFB_PID 2>/dev/null || true
  sleep 1
}

shot() { import -window root "$OUT_DIR/$1.png"; echo "截图已存：$OUT_DIR/$1.png"; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 2; }
nav() { click "$NAV_X" "$1"; }
scroll_down() { xdotool mousemove 800 400 click 5; sleep 1; }

if [ "$MODE" = "probe" ]; then
  setup_db
  launch
  shot "probe-home-$THEME"
  nav "$NAV_COLLECT_Y"; shot "probe-collect-$THEME"
  nav "$NAV_REVIEW_Y"; shot "probe-review-$THEME"
  nav "$NAV_WRONGBOOK_Y"; shot "probe-shelf-$THEME"
  nav "$NAV_REPORT_Y"; shot "probe-report-$THEME"
  stop_app
  echo "探针图完成，库已恢复（trap）"
  exit 0
fi

# 完整模式：深色一遍由交互验证跑过（坐标与此一致），亮色走脚本。
setup_db
launch

# 1) 收集中心：下拉菜单应有化学，点化学后下拉显示化学。
nav "$NAV_COLLECT_Y"
click "$COLLECT_DROPDOWN_X" "$COLLECT_DROPDOWN_Y"
shot "collect-menu-$THEME"
click "$COLLECT_CHEM_X" "$COLLECT_CHEM_Y"
shot "collect-selected-$THEME"

# 2) 复习：学科筛选菜单应有化学，选后列表只剩化学组。
nav "$NAV_REVIEW_Y"
click "$REVIEW_FILTER_X" "$REVIEW_FILTER_Y"
shot "review-menu-$THEME"
click "$REVIEW_CHEM_X" "$REVIEW_CHEM_Y"
shot "review-filtered-$THEME"

# 3) 错题本：进化学书 → 全部题目 → 切紧凑列表，化学行应为紫名。
nav "$NAV_WRONGBOOK_Y"
click "$SHELF_CHEM_X" "$SHELF_CHEM_Y"
shot "wrongbook-dir-$THEME"
click "$DIR_ALL_X" "$DIR_ALL_Y"
click "$COMPACT_TOGGLE_X" "$COMPACT_TOGGLE_Y"
shot "wrongbook-compact-$THEME"

# 4) 学习报告：滚到分布区，弱点行（紫名）与分布行都应有化学。
nav "$NAV_REPORT_Y"
for _ in 1 2 3 4 5; do scroll_down; done
shot "report-dist-$THEME"

stop_app
echo "截图完成，库已恢复（trap）"
