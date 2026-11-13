#!/usr/bin/env bash
# S8 B4.1 截图验证：复查提醒（应用内、进应用时一次）。
#   前置：库已备份到 /tmp/qm2-s8b4-orig.db；本脚本不恢复库，
#   只改 settings 里的 notifyEnabled / notifyTime /
#   lastRecheckReminderDate，跑完由主流程统一恢复。
#   提醒对话框按钮坐标（1280x720 探针图上量得）：
#     「稍后再说」约 (698, 402)，「去复习」约 (775, 402)。
#   杀应用用 pkill -x quiz_master2。
#
# 用法：./run-shots-s8b4-b41.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
OUT_DIR="$ROOT/docs/ui-replication/shots/s8b4"
DB="$HOME/.local/share/quiz-master2/quiz-master2.db"

[ -x "$BIN" ] || { echo "找不到可执行文件：$BIN"; exit 1; }
for c in Xvfb import xdotool sqlite3; do
  command -v "$c" >/dev/null || { echo "未找到 $c"; exit 1; }
done
mkdir -p "$OUT_DIR"

XVFB_PID=""
APP_PID=""

launch() {
  local display_num=99
  while [ -e "/tmp/.X${display_num}-lock" ]; do display_num=$((display_num + 1)); done
  DISPLAY=":$display_num"
  export DISPLAY
  Xvfb "$DISPLAY" -screen 0 1280x720x24 >/dev/null 2>&1 &
  XVFB_PID=$!
  sleep 2
  "$BIN" >/tmp/quiz-master2-s8b4-run.log 2>&1 &
  APP_PID=$!
  sleep 5
}

stop_app() {
  pkill -x quiz_master2 2>/dev/null || true
  sleep 1
  if [ -n "${XVFB_PID:-}" ]; then kill $XVFB_PID 2>/dev/null || true; fi
  sleep 1
  XVFB_PID=""
  APP_PID=""
}

shot() { import -window root "$OUT_DIR/$1.png"; echo "截图已存：$OUT_DIR/$1.png"; }

set_setting() {
  sqlite3 "$DB" "INSERT OR REPLACE INTO settings(key,value) VALUES('$1','$2');"
  echo "设置 $1=$2"
}

clear_reminded() {
  sqlite3 "$DB" "DELETE FROM settings WHERE key='lastRecheckReminderDate';"
  echo "已清除当日提醒记录"
}

reminded() {
  sqlite3 "$DB" "SELECT value FROM settings WHERE key='lastRecheckReminderDate';"
}

# 0) 基线：开关开、提醒时间 00:00（已过），今天没提醒过。
set_setting themeMode dark
set_setting startupPage home
set_setting notifyEnabled 1
set_setting notifyTime 00:00
clear_reminded

# 1) 启动应弹提醒；点「去复习」应进复习页。
launch
shot 03-reminder-shows-again
echo "弹框后 lastRecheckReminderDate=$(reminded)"
DISPLAY="$DISPLAY" xdotool mousemove --sync 775 402 click --clearmodifiers 1
sleep 2
shot 04-reminder-go-review
echo "点去复习后 lastRoute=$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='lastRoute';")"
stop_app

# 2) 同一天重进：不再弹。
launch
shot 05-no-repeat-same-day
stop_app

# 3) 开关关掉：不弹（先清当日记录，排除“一天一次”的干扰）。
clear_reminded
set_setting notifyEnabled 0
launch
shot 06-disabled-no-reminder
stop_app

# 4) 提醒时间还没到（23:59）：不弹（先清当日记录）。
clear_reminded
set_setting notifyEnabled 1
set_setting notifyTime 23:59
launch
shot 07-before-time-no-reminder
stop_app

echo "B4.1 四组截图完成"
