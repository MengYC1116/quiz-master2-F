#!/usr/bin/env bash
# R10 学科管理 + 设置页截图脚手架：在 Xvfb 下以 1280×720 运行 quiz-master2
#（Linux Release 构建产物），按亮/深 × 标准/大/特大字号截两页默认态，
# 另截各展开/选中/弹窗态，存入 docs/ui-replication/shots/r10/。
#
# 用法：
#   ./run-shots-r10.sh                  # 全部截图
#   ./run-shots-r10.sh probe            # 探针：首页 × 三档字号（校准导航 Y 用）
#                                       # + 学科管理/设置默认态（标准档，校准页内坐标用）
#   ./run-shots-r10.sh normal light standard   # 只截一组默认态（两页）
#   ./run-shots-r10.sh states           # 只截各状态
#
# 实现：主题与字号走应用设置（settings 表）；改库的状态改前整库备份到
# 工作区根目录 .qm2-r10-backup.db（不用 /tmp，R4 教训），跑完用备份
# 文件恢复并删除备份。不改代码、不加调试入口。
# 前置：已跑过 flutter build linux --release。
# 注意：Xvfb 下无系统主题设置，主题以 settings 表的 themeMode 为准。
# 点击坐标按字号实测（标准字号 1280×720，见 R10-REPORT §5）：
# 导航“学科管理”Y 353/389/443、“设置”Y 667（标准档；大/特大档设置
# 按钮在首屏外，先滚导航再点，见 go_settings）；页内段头 Y 以默认态
# 为准，点开后页面会上滚（焦点滚动，R1 共享组件既有行为），二次点击
# 须用点开后的实测 Y（见各函数内注释）。章节行只响应文字区，点
# x=350，不要点行内空白 x=700（R10 探针教训）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
OUT_DIR="$ROOT/docs/ui-replication/shots/r10"
DB="$HOME/.local/share/quiz-master2/quiz-master2.db"
BACKUP="$ROOT/.qm2-r10-backup.db"

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
  "$BIN" >/tmp/quiz-master2-r10-run.log 2>&1 &
  APP_PID=$!
  sleep 5
}

stop_app() {
  kill $APP_PID 2>/dev/null || true
  wait $APP_PID 2>/dev/null || true
  kill $XVFB_PID 2>/dev/null || true
}

click() { xdotool mousemove "$1" "$2" click 1; sleep 2; }
scroll_down() { local n="$1"; for _ in $(seq "$n"); do xdotool mousemove 700 400 click 5; sleep 1; done; }
shot() { import -window root "$OUT_DIR/$1.png"; echo "截图已存：$OUT_DIR/$1.png"; }

set_theme_font() {
  sqlite3 "$DB" "UPDATE settings SET value='$1' WHERE key='themeMode'; UPDATE settings SET value='$2' WHERE key='fontSize';"
}

# 导航“学科管理”Y（1280×720 像素扫描实测，探针校准）：
# 标准 353 / 大 389 / 特大 443。
nav_subjects_y() {
  case "$1" in
    large) echo 389 ;;
    extraLarge) echo 443 ;;
    *) echo 353 ;;
  esac
}

go_subjects() { click 100 "$(nav_subjects_y "$1")"; }

# 导航“设置”：标准档 Y 667 可直接点；大/特大档设置按钮在首屏外，
# 先在导航区滚（大 6 次、特大 8 次，像素扫描实测滚后 Y 大 678/特大 674）。
go_settings() {
  case "$1" in
    large)
      for _ in 1 2 3 4 5 6; do xdotool mousemove 100 400 click 5; sleep 1; done
      click 100 678
      ;;
    extraLarge)
      for _ in 1 2 3 4 5 6 7 8; do xdotool mousemove 100 400 click 5; sleep 1; done
      click 100 674
      ;;
    *) click 100 667 ;;
  esac
}

# 默认态段头 Y（标准档，默认态探针 scan-text 实测）：
# 学科管理：学科 279 / 知识点树 348 / 标签 415 / 试卷 483；
# 设置：外观 245 / 复习 313 / 错题本 382 / 数据 449 / 启动与关于 518。
shot_normal() {
  local theme="$1" font="$2"
  set_theme_font "$theme" "$font"
  launch
  go_subjects "$font"
  shot "subjects-$theme-$font"
  go_settings "$font"
  shot "settings-$theme-$font"
  stop_app
}

shot_probe() {
  # 首页 × 三档字号（校准导航 Y 用）。
  for font in standard large extraLarge; do
    set_theme_font dark "$font"
    launch
    shot "probe-home-dark-$font"
    stop_app
  done
  # 两页默认态（标准档，校准页内控件坐标用）。
  set_theme_font dark standard
  launch
  go_subjects standard
  shot probe-subjects-dark-standard
  go_settings standard
  shot probe-settings-dark-standard
  stop_app
}

if [ $# -eq 1 ] && [ "$1" = "probe" ]; then
  shot_probe
  exit 0
fi

if [ $# -eq 3 ] && [ "$1" = "normal" ]; then
  shot_normal "$2" "$3"
  exit 0
fi

shot_states() {
  # ---- 学科管理各态（亮色标准档，每态新开一次应用，避免上滚位移累积）。
  set_theme_font light standard
  launch
  go_subjects standard
  click 700 279
  shot subjects-open-light-standard
  stop_app

  # 封面块：学科段点开后，封面头 Y 422（点开后实测）。
  launch
  go_subjects standard
  click 700 279
  click 700 422
  shot subjects-cover-light-standard
  stop_app

  # 封面块（深色标准）：同上。
  set_theme_font dark standard
  launch
  go_subjects standard
  click 700 279
  click 700 422
  shot subjects-cover-dark-standard
  stop_app
  set_theme_font light standard

  # 知识点树展开一章：知识点树段头 348；点开后第一章行在 Y 356，
  # 点文字区 x=350（行内空白 x=700 点不到，见 R10-REPORT）。
  launch
  go_subjects standard
  click 700 348
  click 350 356
  shot subjects-kp-open-light-standard
  stop_app

  # 删学科确认：学科段点开后，数学行删除按钮 (1205,229)。
  launch
  go_subjects standard
  click 700 279
  click 1205 229
  shot subjects-delconfirm-light-standard
  stop_app

  # 试卷搜索无匹配：试卷段头 483；点开后搜索框 Y 411（点开后实测；
  # 注意 Y 221 是点开后移到该处的知识点树段头，点它会切到知识点树，
  # R10 探针教训）。
  launch
  go_subjects standard
  click 700 483
  click 700 411
  xdotool key U4E0D U5B58 U5728 U7684 U5377 U5B50
  sleep 2
  shot subjects-exams-search-light-standard
  stop_app

  # ---- 设置各态（亮色标准档）。
  launch
  go_settings standard
  click 700 245
  shot settings-appearance-light-standard
  stop_app

  launch
  go_settings standard
  click 700 313
  shot settings-review-light-standard
  # 下滚看提醒时间与复习列表默认排序两行。
  scroll_down 3
  shot settings-review-scrolled-light-standard
  stop_app

  launch
  go_settings standard
  click 700 382
  shot settings-wrongbook-light-standard
  stop_app

  launch
  go_settings standard
  click 700 449
  shot settings-data-light-standard
  stop_app

  launch
  go_settings standard
  click 700 518
  shot settings-startup-light-standard
  stop_app
}

if [ $# -eq 1 ] && [ "$1" = "states" ]; then
  shot_states
  exit 0
fi

shot_normal light standard
shot_normal light large
shot_normal light extraLarge
shot_normal dark standard
shot_normal dark large
shot_normal dark extraLarge
shot_states

echo "全部截图完成，库已恢复（trap）"
