#!/usr/bin/env bash
# R6 错题本截图脚手架：在 Xvfb 下以 1280×720 运行 quiz-master2（Linux Release
# 构建产物），按亮/深 × 标准/大/特大字号截书架 / 目录 / 列表，另截展开、
# 筛选、批量、已归档、删除确认、选择移动、空状态（书架无题 / 列表搜不到）、
# 紧凑列表，存入 docs/ui-replication/shots/r6/。
#
# 用法：
#   ./run-shots-r6.sh                  # 全部截图
#   ./run-shots-r6.sh probe            # 只截一张书架探针（校准点击坐标用）
#   ./run-shots-r6.sh normal light standard   # 只截一组书架正常态
#   ./run-shots-r6.sh states           # 只截各状态（展开/筛选/批量/归档/确认/选择/空）
#
# 实现：主题与字号走应用设置（settings 表）；改库的状态改前整库备份到
# 工作区根目录 .qm2-r6-backup.db（不用 /tmp，R4 教训），跑完用备份
# 文件恢复并删除备份。不改代码、不加调试入口。
# 前置：已跑过 flutter build linux --release。
# 注意：Xvfb 下无系统主题设置，主题以 settings 表的 themeMode 为准。
# 点击坐标按字号实测（标准字号 1280×720）：导航错题本 (100,225)；
# 数学书封面中心约 (413,300)；目录「全部题目」行约 (500,255)；
# 其余见各函数内注释。改坐标只改本文件顶部变量。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
OUT_DIR="$ROOT/docs/ui-replication/shots/r6"
DB="$HOME/.local/share/quiz-master2/quiz-master2.db"
BACKUP="$ROOT/.qm2-r6-backup.db"

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
  "$BIN" >/tmp/quiz-master2-r6-run.log 2>&1 &
  APP_PID=$!
  sleep 5
}

stop_app() {
  kill $APP_PID 2>/dev/null || true
  wait $APP_PID 2>/dev/null || true
  kill $XVFB_PID 2>/dev/null || true
}

click() { xdotool mousemove "$1" "$2" click 1; sleep 2; }
type_text() { LC_ALL=C.UTF-8 xdotool type --delay 60 "$1"; sleep 2; }
shot() { import -window root "$OUT_DIR/$1.png"; echo "截图已存：$OUT_DIR/$1.png"; }

set_theme_font() {
  sqlite3 "$DB" "UPDATE settings SET value='$1' WHERE key='themeMode'; UPDATE settings SET value='$2' WHERE key='fontSize';"
}

# 错题本导航 Y（标准 225 / 大 247 / 特大 285，1280×720 实测）。
nav_wrongbook_y() {
  case "$1" in
    large) echo 247 ;;
    extraLarge) echo 285 ;;
    *) echo 225 ;;
  esac
}

# 书架数学书封面中心（标准字号实测；大/特大档书封面更高，中心下移）。
book_math_xy() {
  case "$1" in
    large) echo "430 420" ;;
    extraLarge) echo "430 445" ;;
    *) echo "430 400" ;;
  esac
}

# 目录页「全部题目」行中心（实测：行高约 45–60px，(500,310) 在三档都落在行内）。
all_row_xy() {
  echo "500 310"
}

# 进书架。
go_shelf() { click 100 "$(nav_wrongbook_y "$1")"; }
# 进目录（数学书）。
go_directory() {
  local font="$1"
  go_shelf "$font"
  local xy
  xy=$(book_math_xy "$font")
  # shellcheck disable=SC2086
  click $xy
}
# 进列表（数学书 → 全部题目）。
go_list() {
  local font="$1"
  go_directory "$font"
  local xy
  xy=$(all_row_xy "$font")
  # shellcheck disable=SC2086
  click $xy
}

shot_shelf() {
  local theme="$1" font="$2" name="$3"
  set_theme_font "$theme" "$font"
  launch
  go_shelf "$font"
  shot "$name"
  stop_app
}

shot_directory() {
  local theme="$1" font="$2" name="$3"
  set_theme_font "$theme" "$font"
  launch
  go_directory "$font"
  shot "$name"
  stop_app
}

shot_list() {
  local theme="$1" font="$2" name="$3"
  set_theme_font "$theme" "$font"
  launch
  go_list "$font"
  shot "$name"
  stop_app
}

shot_probe() {
  set_theme_font dark standard
  launch
  go_shelf standard
  shot probe-shelf-dark-standard
  stop_app
}

shot_states() {
  # 目录展开子文件夹（深色标准）：真实库暂无子文件夹，先插一个临时的
  # “期中试卷”（数学 · 试卷的子文件夹），再点 ▸（约 313,377）；拍完恢复库。
  sqlite3 "$DB" "INSERT INTO folders (id,name,subject_id,parent_id,sort_order) VALUES ('folder-math-期中','期中试卷','math','folder-math-试卷',0);"
  set_theme_font dark standard
  launch
  go_directory standard
  click 313 377
  shot wrongbook-directory-expanded-dark-standard
  stop_app
  cp "$BACKUP" "$DB"

  # 列表筛选面板打开（亮色标准）：进列表 → 点「筛选 ▾」芯片（约 640,162）。
  set_theme_font light standard
  launch
  go_list standard
  click 640 162
  shot wrongbook-list-filter-light-standard
  stop_app

  # 列表批量模式 + 全选（深色标准）：进列表 → 点「批量操作」（约 305,210）
  # → 点批量条的「全选当前结果」复选框（约 300,265），已选 2 道。
  set_theme_font dark standard
  launch
  go_list standard
  click 305 210
  click 300 265
  shot wrongbook-list-batch-dark-standard
  stop_app

  # 紧凑列表（亮色标准）：进列表 → 点「紧凑列表」（约 1095,162）。
  set_theme_font light standard
  launch
  go_list standard
  click 1095 162
  shot wrongbook-list-compact-light-standard
  stop_app

  # 已归档视图（亮色标准）：先把 1 道题归档 → 书架点「已归档（1）」（约 278,178）。
  sqlite3 "$DB" "UPDATE questions SET is_archived=1 WHERE id IN (SELECT id FROM questions WHERE is_organized=1 LIMIT 1);"
  set_theme_font light standard
  launch
  go_shelf standard
  click 278 178
  shot wrongbook-archived-light-standard
  stop_app
  cp "$BACKUP" "$DB"

  # 目录删除确认（深色标准）：进目录 → 点首行「删除」（约 1185,377）。
  set_theme_font dark standard
  launch
  go_directory standard
  click 1185 377
  shot wrongbook-directory-delete-dark-standard
  stop_app

  # 目录选择移动模式（深色标准）：进目录 → 点「选择文件夹」（约 1150,222）
  # → 点「试卷」行勾选（选择条出现后各行下移约 68px，约 500,445）。
  set_theme_font dark standard
  launch
  go_directory standard
  click 1150 222
  click 500 445
  shot wrongbook-directory-select-dark-standard
  stop_app

  # 列表搜不到（亮色标准）：进列表 → 点搜索框（约 445,162）→ 输入无匹配词。
  # xdotool type 在 C locale 下打不了中文，搜不到用 ASCII "zzzz" 即可。
  set_theme_font light standard
  launch
  go_list standard
  click 445 162
  type_text "zzzz"
  shot wrongbook-list-empty-light-standard
  stop_app

  # 书架空状态（深色标准）：库里无题。
  sqlite3 "$DB" "DELETE FROM questions;"
  set_theme_font dark standard
  launch
  go_shelf standard
  shot wrongbook-shelf-empty-dark-standard
  stop_app
  cp "$BACKUP" "$DB"
}

if [ $# -eq 1 ] && [ "$1" = "probe" ]; then
  shot_probe
  exit 0
fi

if [ $# -eq 3 ] && [ "$1" = "normal" ]; then
  shot_shelf "$2" "$3" "wrongbook-shelf-$2-$3"
  exit 0
fi

if [ $# -eq 1 ] && [ "$1" = "states" ]; then
  shot_states
  exit 0
fi

shot_shelf light standard wrongbook-shelf-light-standard
shot_shelf light large wrongbook-shelf-light-large
shot_shelf light extraLarge wrongbook-shelf-light-extraLarge
shot_shelf dark standard wrongbook-shelf-dark-standard
shot_shelf dark large wrongbook-shelf-dark-large
shot_shelf dark extraLarge wrongbook-shelf-dark-extraLarge
shot_directory light standard wrongbook-directory-light-standard
shot_directory dark standard wrongbook-directory-dark-standard
shot_directory light large wrongbook-directory-light-large
shot_directory dark extraLarge wrongbook-directory-dark-extraLarge
shot_list light standard wrongbook-list-light-standard
shot_list dark standard wrongbook-list-dark-standard
shot_list light large wrongbook-list-light-large
shot_list dark extraLarge wrongbook-list-dark-extraLarge
shot_states

echo "全部截图完成，库已恢复（trap）"
