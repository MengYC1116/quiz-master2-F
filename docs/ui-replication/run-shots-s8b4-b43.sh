#!/usr/bin/env bash
# S8 B4.3 真机验证：切换数据库位置时迁移旧库。
#   migrate       ：选空目录 → 直接迁移（无已存在库），截迁移提示
#   relaunch-newloc：重启后设置页应显示新位置路径
#   dialog-keep    ：选已有库的目录 → 弹“覆盖 / 保留”对话框（截完停住）
#   dialog-default ：选默认目录（已有库）→ 弹对话框（截完停住）
# 垫片见 /tmp/qm2-bin/zenity（本机 zenity 不支持 --directory）。
# 杀应用用 pkill -x quiz_master2。
#
# 用法：./run-shots-s8b4-b43.sh <migrate|relaunch-newloc|dialog-keep|dialog-default>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
OUT_DIR="$ROOT/docs/ui-replication/shots/s8b4"
DB="$HOME/.local/share/quiz-master2/quiz-master2.db"
DEF_DIR="$HOME/.local/share/quiz-master2"
NEWLOC="/tmp/qm2-s8b4-newloc"
KEEP="/tmp/qm2-s8b4-keep"

[ -x "$BIN" ] || { echo "找不到可执行文件：$BIN"; exit 1; }
for c in Xvfb import xdotool sqlite3; do
  command -v "$c" >/dev/null || { echo "未找到 $c"; exit 1; }
done
mkdir -p "$OUT_DIR"
# 垫片 zenity：本机 zenity 4.0.1 精简版不支持 file_picker 要用的
# --save / --file-filter / --directory，调了就直接报错退出，与应用无关。
# 垫片按参数返回固定选择（见 S8B4-REPORT.md），只在本次验证的 PATH 里
# 生效；脚本每次跑都重建它，不依赖 /tmp 里的旧文件。
mkdir -p /tmp/qm2-bin
cat > /tmp/qm2-bin/zenity << 'SHIM_EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    --save) echo "${QM2_ZENITY_SAVE_FILE:-$HOME/quiz-master2-backup.json}"; exit 0;;
    --directory) echo "${QM2_ZENITY_PICK_DIR:-$HOME}"; exit 0;;
  esac
done
echo "${QM2_ZENITY_PICK_FILE:-$HOME/quiz-master2-backup.json}"
SHIM_EOF
chmod +x /tmp/qm2-bin/zenity
export PATH="/tmp/qm2-bin:$PATH"

XVFB_PID=""
STAGE="${1:-}"

launch() {
  local display_num=99
  while [ -e "/tmp/.X${display_num}-lock" ]; do display_num=$((display_num + 1)); done
  DISPLAY=":$display_num"
  export DISPLAY
  Xvfb "$DISPLAY" -screen 0 1280x720x24 >/dev/null 2>&1 &
  XVFB_PID=$!
  sleep 2
  "$BIN" >/tmp/quiz-master2-s8b4-run.log 2>&1 &
  sleep 5
}

stop_app() {
  pkill -x quiz_master2 2>/dev/null || true
  sleep 1
  if [ -n "${XVFB_PID:-}" ]; then kill $XVFB_PID 2>/dev/null || true; fi
  sleep 1
  XVFB_PID=""
}

shot() { import -window root "$OUT_DIR/$1.png"; echo "截图已存：$OUT_DIR/$1.png"; }

open_settings_data() {
  DISPLAY="$DISPLAY" xdotool mousemove --sync 105 650 click --clearmodifiers 1
  sleep 2
  DISPLAY="$DISPLAY" xdotool mousemove --sync 740 300 click --clearmodifiers 1
  sleep 2
}

click_change_location() {
  # 「改位置」按钮 y 随路径换行变：一行路径时约 512，两行时约 530。
  # 调用时传 y。
  local y="${1:-512}"
  DISPLAY="$DISPLAY" xdotool mousemove --sync 1190 "$y" click --clearmodifiers 1
  sleep 2
}

marker() { cat "$DEF_DIR/db_location.txt" 2>/dev/null || echo "(无标记文件)"; }

case "$STAGE" in
  migrate)
    rm -rf "$NEWLOC"; mkdir -p "$NEWLOC"
    export QM2_ZENITY_PICK_DIR="$NEWLOC"
    launch
    open_settings_data
    click_change_location 530
    shot 16-migrated-snack
    stop_app
    echo "--- 迁移后："
    echo "标记文件：$(marker)"
    ls -la "$NEWLOC"
    sqlite3 "$NEWLOC/quiz-master2.db" "SELECT 'questions=' || COUNT(*) FROM questions; SELECT 'collect_tasks=' || COUNT(*) FROM collect_tasks; SELECT 'recent_tasks=' || title FROM recent_tasks;"
    ;;
  relaunch-newloc)
    launch
    open_settings_data
    shot 17-new-location
    stop_app
    echo "标记文件：$(marker)"
    ;;
  dialog-keep)
    rm -rf "$KEEP"; mkdir -p "$KEEP"
    cp "$NEWLOC/quiz-master2.db" "$KEEP/quiz-master2.db"
    sqlite3 "$KEEP/quiz-master2.db" "UPDATE recent_tasks SET title='keep-marker' WHERE id=1;"
    echo "keep 库 recent_tasks 标题：$(sqlite3 "$KEEP/quiz-master2.db" "SELECT title FROM recent_tasks;")"
    export QM2_ZENITY_PICK_DIR="$KEEP"
    launch
    open_settings_data
    click_change_location 512
    shot 18-target-exists-dialog
    echo "对话框已截（18-target-exists-dialog.png），应用仍在跑，等按钮坐标。"
    ;;
  dialog-default)
    export QM2_ZENITY_PICK_DIR="$DEF_DIR"
    launch
    open_settings_data
    click_change_location 512
    shot 21-target-exists-dialog-default
    echo "对话框已截（21-target-exists-dialog-default.png），应用仍在跑，等按钮坐标。"
    ;;
  *)
    echo "用法：$0 <migrate|relaunch-newloc|dialog-keep|dialog-default>"
    exit 1
    ;;
esac
