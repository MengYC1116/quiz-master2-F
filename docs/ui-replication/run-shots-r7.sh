#!/usr/bin/env bash
# R7 题目详情截图脚手架：在 Xvfb 下以 1280×720 运行 quiz-master2（Linux Release
# 构建产物），按亮/深 × 标准/大/特大字号截详情页默认态，另截展开（答案解析 /
# 题目信息 / 复习记录）、编辑、删除确认、放大浮层、空内容、已收藏（选中态），
# 存入 docs/ui-replication/shots/r7/。
#
# 用法：
#   ./run-shots-r7.sh                  # 全部截图
#   ./run-shots-r7.sh probe            # 探针：进列表 + 点首张卡进详情（校准点击坐标用）
#   ./run-shots-r7.sh normal light standard   # 只截一组详情默认态
#   ./run-shots-r7.sh states           # 只截各状态（展开/编辑/删除/放大/空/收藏）
#
# 实现：主题与字号走应用设置（settings 表）；改库的状态改前整库备份到
# 工作区根目录 .qm2-r7-backup.db（不用 /tmp，R4 教训），跑完用备份
# 文件恢复并删除备份。不改代码、不加调试入口。
# 前置：已跑过 flutter build linux --release。
# 注意：Xvfb 下无系统主题设置，主题以 settings 表的 themeMode 为准。
# 点击坐标按字号实测（标准字号 1280×720）：导航错题本 (100,225)；
# 数学书封面中心约 (430,400)；目录「全部题目」行约 (500,310)；
# 列表首张卡中心约 (640,300)（probe 校准）；其余见各函数内注释。
# 详情页是 Navigator.push 的全窗页（无左导航，基线架构），内容宽上限 1004
# 居中；折叠头 / 底部操作行常在 720 高视口外，点按前须先滚到可见
#（Page_Down / wheel），见 scroll_down。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
OUT_DIR="$ROOT/docs/ui-replication/shots/r7"
DB="$HOME/.local/share/quiz-master2/quiz-master2.db"
BACKUP="$ROOT/.qm2-r7-backup.db"

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
  "$BIN" >/tmp/quiz-master2-r7-run.log 2>&1 &
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
# 向下滚一屏（详情页整页滚动；折叠头 / 底部操作行在 720 高视口外时先滚）。
scroll_down() { xdotool mousemove 640 360 click 5; sleep 1; }
scroll_down_n() { for _ in $(seq "$1"); do scroll_down; done; }

set_theme_font() {
  sqlite3 "$DB" "UPDATE settings SET value='$1' WHERE key='themeMode'; UPDATE settings SET value='$2' WHERE key='fontSize';"
}

# 错题本导航 Y（标准 225 / 大 247 / 特大 285，1280×720 实测，R6）。
nav_wrongbook_y() {
  case "$1" in
    large) echo 247 ;;
    extraLarge) echo 285 ;;
    *) echo 225 ;;
  esac
}

# 书架数学书封面中心（标准 430,400；大 430,420；特大 430,445，R6）。
book_math_xy() {
  case "$1" in
    large) echo "430 420" ;;
    extraLarge) echo "430 445" ;;
    *) echo "430 400" ;;
  esac
}

# 目录页「全部题目」行中心（R6：500,310 三档通用）。
all_row_xy() {
  echo "500 310"
}

# 列表首张卡中心（标准档实测，见 probe；大/特大档卡更高，中心下移）。
first_card_xy() {
  case "$1" in
    large) echo "640 330" ;;
    extraLarge) echo "640 360" ;;
    *) echo "640 300" ;;
  esac
}

# 第二张卡中心（数学列表第 2 张 = 函数极限 q-math-1，已收藏 ★；probe 实测标准档约 640,495）。
second_card_xy() {
  case "$1" in
    large) echo "640 525" ;;
    extraLarge) echo "640 570" ;;
    *) echo "640 495" ;;
  esac
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
# 进详情（列表 → 首张卡 = 定积分阴影面积 q-math-3）。
go_detail() {
  local font="$1"
  go_list "$font"
  local xy
  xy=$(first_card_xy "$font")
  # shellcheck disable=SC2086
  click $xy
}
# 进详情（列表 → 第二张卡 = 函数极限 q-math-1，已收藏 ★）。
go_detail_second() {
  local font="$1"
  go_list "$font"
  local xy
  xy=$(second_card_xy "$font")
  # shellcheck disable=SC2086
  click $xy
}

# 详情页折叠头 Y（标准档实测；内容宽居中，折叠头横跨内容区，x 取 400 落在标题上）。
# 注意：点折叠头前须保证它在视口内；默认态三段都在首屏下半部附近。
fold_xy() {
  # $1 = 第几个折叠头（1 答案解析 / 2 题目信息 / 3 复习记录），$2 = 字号
  local n="$1" font="$2"
  case "$font" in
    large)
      case "$n" in 1) echo "400 590" ;; 2) echo "400 655" ;; *) echo "400 720" ;; esac ;;
    extraLarge)
      case "$n" in 1) echo "400 610" ;; 2) echo "400 680" ;; *) echo "400 745" ;; esac ;;
    *)
      case "$n" in 1) echo "400 568" ;; 2) echo "400 627" ;; *) echo "400 685" ;; esac ;;
  esac
}

shot_detail() {
  local theme="$1" font="$2" name="$3"
  set_theme_font "$theme" "$font"
  launch
  go_detail "$font"
  shot "$name"
  stop_app
}

shot_probe() {
  set_theme_font dark standard
  launch
  go_list standard
  shot probe-list-dark-standard
  local xy
  xy=$(first_card_xy standard)
  # shellcheck disable=SC2086
  click $xy
  shot probe-detail-dark-standard
  stop_app
}

shot_states() {
  # 答案解析展开 + 看答案（亮色标准）：进详情 → 点「答案解析」折叠头
  # → 点「看答案」主按钮（约 200,585）。
  set_theme_font light standard
  launch
  go_detail standard
  local xy
  xy=$(fold_xy 1 standard)
  # shellcheck disable=SC2086
  click $xy
  click 200 610
  shot detail-answer-light-standard
  stop_app

  # 题目信息展开（深色标准）：进详情 → 点「题目信息」折叠头。
  set_theme_font dark standard
  launch
  go_detail standard
  xy=$(fold_xy 2 standard)
  # shellcheck disable=SC2086
  click $xy
  shot detail-info-dark-standard
  stop_app

  # 复习记录展开（亮色标准）：进详情 → 点「复习记录」折叠头。
  set_theme_font light standard
  launch
  go_detail standard
  xy=$(fold_xy 3 standard)
  # shellcheck disable=SC2086
  click $xy
  shot detail-review-light-standard
  stop_app

  # 编辑态（亮色标准）：进详情 → 点右上角「编辑」（约 1090,45）。
  set_theme_font light standard
  launch
  go_detail standard
  click 903 45
  shot detail-edit-light-standard
  stop_app

  # 删除确认（深色标准）：进详情 → 滚到底部 → 点「删除」（滚后像素实测约 785,665（按钮文本中心））。
  set_theme_font dark standard
  launch
  go_detail standard
  scroll_down_n 3
  click 785 665
  scroll_down_n 2
  shot detail-delete-dark-standard
  stop_app

  # 放大浮层（亮色标准）：进详情 → 点整题图中心（约 640,330）。
  set_theme_font light standard
  launch
  go_detail standard
  click 640 345
  shot detail-zoom-light-standard
  stop_app

  # 空内容（亮色标准）：先把 q-math-3 的答案/解析/备注置空 → 进详情，
  # 空内容横幅 + 待补充；拍完恢复库。
  sqlite3 "$DB" "UPDATE questions SET answer=NULL, explanation=NULL, notes=NULL WHERE id='q-math-3';"
  set_theme_font light standard
  launch
  go_detail standard
  shot detail-empty-light-standard
  stop_app
  cp "$BACKUP" "$DB"

  # 已收藏选中态（深色标准）：进列表 → 点第二张卡（函数极限 ★）。
  set_theme_font dark standard
  launch
  go_detail_second standard
  shot detail-favorite-dark-standard
  stop_app
}

if [ $# -eq 1 ] && [ "$1" = "probe" ]; then
  shot_probe
  exit 0
fi

if [ $# -eq 3 ] && [ "$1" = "normal" ]; then
  shot_detail "$2" "$3" "detail-$2-$3"
  exit 0
fi

if [ $# -eq 1 ] && [ "$1" = "states" ]; then
  shot_states
  exit 0
fi

shot_detail light standard detail-light-standard
shot_detail light large detail-light-large
shot_detail light extraLarge detail-light-extraLarge
shot_detail dark standard detail-dark-standard
shot_detail dark large detail-dark-large
shot_detail dark extraLarge detail-dark-extraLarge
shot_states

echo "全部截图完成，库已恢复（trap）"
