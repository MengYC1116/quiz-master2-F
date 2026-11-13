#!/usr/bin/env bash
# S8 B3 截图验证：启动页设置生效。
#   probe 模式：只启动截一张首页探针图（用来量导航项点击坐标）。
#   完整模式：
#     1) startupPage=last、lastRoute=/home → 启动落首页；
#     2) 点左侧导航「整理工作台」→ 截图 + 查库 lastRoute 应为 /organize；
#     3) 退出重进 → 应恢复整理工作台（截图核对）；
#     4) startupPage 改回 home、退出重进 → 应落首页（截图核对）。
#   改库前整库备份到工作区根目录 .qm2-s8b3-backup.db，跑完恢复并删除
#   备份；恢复态按任务要求：9 道题、3 学科、深色、启动页 home。
#   杀应用用 pkill -x quiz_master2。
#
# 用法：
#   ./run-shots-s8b3.sh probe    # 只截探针图
#   ./run-shots-s8b3.sh          # 完整四张
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
OUT_DIR="$ROOT/docs/ui-replication/shots/s8b3"
DB="$HOME/.local/share/quiz-master2/quiz-master2.db"
BACKUP="$ROOT/.qm2-s8b3-backup.db"

[ -x "$BIN" ] || { echo "找不到可执行文件：$BIN"; echo "请先跑 flutter build linux --release"; exit 1; }
for c in Xvfb import xdotool sqlite3; do
  command -v "$c" >/dev/null || { echo "未找到 $c"; exit 1; }
done

mkdir -p "$OUT_DIR"

# 「整理工作台」导航项坐标（1280x720 探针图上量得：行中心约 y=172）。
NAV_ORGANIZE_X=100
NAV_ORGANIZE_Y=172

cp "$DB" "$BACKUP"
echo "原库已备份到 $BACKUP"

restore() {
  pkill -x quiz_master2 2>/dev/null || true
  sleep 1
  cp "$BACKUP" "$DB"
  rm -f "$BACKUP"
  # 任务要求的恢复态：9 道题、3 学科、深色、启动页 home。
  sqlite3 "$DB" "INSERT OR REPLACE INTO settings(key,value) VALUES('themeMode','dark'); INSERT OR REPLACE INTO settings(key,value) VALUES('startupPage','home'); INSERT OR REPLACE INTO settings(key,value) VALUES('lastRoute','/home');"
  echo "库已恢复，备份已删除"
  sqlite3 "$DB" "SELECT 'subjects=' || COUNT(*) FROM subjects; SELECT 'questions=' || COUNT(*) FROM questions; SELECT key || '=' || value FROM settings WHERE key IN ('themeMode','startupPage','lastRoute');"
}
trap restore EXIT

set_setting() {
  sqlite3 "$DB" "INSERT OR REPLACE INTO settings(key,value) VALUES('$1','$2');"
  echo "设置 $1=$2"
}

last_route() {
  sqlite3 "$DB" "SELECT value FROM settings WHERE key='lastRoute';"
}

launch() {
  local display_num=99
  while [ -e "/tmp/.X${display_num}-lock" ]; do display_num=$((display_num + 1)); done
  DISPLAY=":$display_num"
  export DISPLAY
  Xvfb "$DISPLAY" -screen 0 1280x720x24 >/dev/null 2>&1 &
  XVFB_PID=$!
  sleep 2
  "$BIN" >/tmp/quiz-master2-s8b3-run.log 2>&1 &
  sleep 5
}

stop_app() {
  pkill -x quiz_master2 2>/dev/null || true
  sleep 1
  kill $XVFB_PID 2>/dev/null || true
  sleep 1
}

shot() { import -window root "$OUT_DIR/$1.png"; echo "截图已存：$OUT_DIR/$1.png"; }

click_organize() {
  xdotool mousemove "$NAV_ORGANIZE_X" "$NAV_ORGANIZE_Y" click 1
  sleep 2
}

if [ $# -eq 1 ] && [ "$1" = "probe" ]; then
  set_setting themeMode dark
  launch
  shot probe-home-dark
  stop_app
  exit 0
fi

# 1) 启动页=last，当前 lastRoute=/home，启动应落首页。
set_setting themeMode dark
set_setting startupPage last
launch
shot 01-start-last-home
click_organize
shot 02-organize-after-click
echo "点击整理工作台后 lastRoute=$(last_route)"
stop_app

# 2) 退出重进：应恢复整理工作台。
launch
shot 03-restart-restores-organize
echo "重进后 lastRoute=$(last_route)"
stop_app

# 3) 改回首页，重进应落首页。
set_setting startupPage home
launch
shot 04-start-home-again
stop_app

echo "四张截图完成，库已恢复（trap）"
