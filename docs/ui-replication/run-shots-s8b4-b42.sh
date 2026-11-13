#!/usr/bin/env bash
# S8 B4.2 真机验证：备份（应用内点备份题库 → 垫片 zenity 返回路径 →
# 应用写文件）与恢复（选含标记行的备份 → 内联确认 → 恢复后 4 张表
# 标记行回来）。前置：演示库已备份到 /tmp/qm2-s8b4-orig.db；
# 含标记行的备份在 shots/s8b4/quiz-master2-backup-s8b4.json。
# 垫片见 /tmp/qm2-bin/zenity（本机 zenity 不支持 --save/--file-filter）。
# 杀应用用 pkill -x quiz_master2。
#
# 用法：./run-shots-s8b4-b42.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
OUT_DIR="$ROOT/docs/ui-replication/shots/s8b4"
DB="$HOME/.local/share/quiz-master2/quiz-master2.db"
APP_BACKUP="$OUT_DIR/quiz-master2-backup-app.json"
ARTIFACT_BACKUP="$OUT_DIR/quiz-master2-backup-s8b4.json"

[ -x "$BIN" ] || { echo "找不到可执行文件：$BIN"; exit 1; }
[ -f "$ARTIFACT_BACKUP" ] || { echo "找不到含标记行的备份：$ARTIFACT_BACKUP"; exit 1; }
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
export QM2_ZENITY_SAVE_FILE="$APP_BACKUP"
export QM2_ZENITY_PICK_FILE="$ARTIFACT_BACKUP"

XVFB_PID=""

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

rm -f "$APP_BACKUP"
launch
open_settings_data
# 1) 点「备份题库」：垫片返回路径，应用写文件。
DISPLAY="$DISPLAY" xdotool mousemove --sync 1172 357 click --clearmodifiers 1
sleep 2
shot 13-backup-saved
stop_app

echo "--- 应用写的备份文件："
ls -la "$APP_BACKUP"
python3 - "$APP_BACKUP" << 'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
print('tables:', len(d), sorted(d.keys()))
for t in ['subjects','questions','cause_records','collect_tasks','review_state','review_history','recent_tasks','settings']:
    print(f'  {t}: {len(d[t])} rows')
print('  recent_tasks:', d['recent_tasks'])
EOF

# 2) 恢复：选含标记行的备份 → 内联确认出现（截图后停住，由操作者
#    量确认按钮坐标再点；本脚本只做到确认框出现）。
launch
open_settings_data
DISPLAY="$DISPLAY" xdotool mousemove --sync 1172 424 click --clearmodifiers 1
sleep 2
shot 14-restore-confirm
echo "恢复确认框已截（14-restore-confirm.png），应用仍在跑，等确认按钮坐标。"
