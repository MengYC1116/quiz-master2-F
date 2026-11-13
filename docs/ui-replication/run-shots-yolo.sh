#!/usr/bin/env bash
# YOLO 第 1 层端到端截图验证：导入真实试卷页 → 修框（真实检测）→
# 内框模式 → 取消留修框中。
#
# 前置：演示库已备份到 /tmp/qm2-demo-backup.db；跑完须把库恢复回去
# （本脚本最后一步自动恢复）。测试图在 ~/workspace/yolo-test-images/，
# 本脚本只用第 3 张（1iMDN…，13 道题、无重叠，修框可直接确认）。
# 杀应用用 pkill -x quiz_master2，不要用含路径的 -f 模式。
#
# 用法：./run-shots-yolo.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
OUT_DIR="$ROOT/docs/ui-replication/shots/yolo"
DB="$HOME/.local/share/quiz-master2/quiz-master2.db"
IMG_DIR="$HOME/workspace/yolo-test-images"
IMG="$IMG_DIR/1iMDN14nE6qZD_srN4VHi1yCZ5j6ywg_D.png"

[ -x "$BIN" ] || { echo "找不到可执行文件：$BIN，先 flutter build linux --release"; exit 1; }
[ -f "$IMG" ] || { echo "找不到测试图：$IMG"; exit 1; }
for c in Xvfb import xdotool; do
  command -v "$c" >/dev/null || { echo "未找到 $c"; exit 1; }
done
mkdir -p "$OUT_DIR"

# 垫片 zenity：本机 zenity 4.0.1 精简版不支持 file_picker 要用的
# --save / --file-filter，调了就直接报错退出，与应用无关。
# 垫片按参数返回固定选择，只在本次验证的 PATH 里生效。
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
export QM2_ZENITY_PICK_FILE="$IMG"

# 演示库备份（没有就先备一份；已有则不动）。
[ -f /tmp/qm2-demo-backup.db ] || cp "$DB" /tmp/qm2-demo-backup.db

XVFB_PID=""
launch() {
  local display_num=99
  while [ -e "/tmp/.X${display_num}-lock" ]; do display_num=$((display_num + 1)); done
  DISPLAY=":$display_num"
  export DISPLAY
  Xvfb "$DISPLAY" -screen 0 1280x720x24 >/tmp/xvfb-yolo.log 2>&1 &
  XVFB_PID=$!
  sleep 2
  # 在测试图目录启动：detectPage 按文件名找文件，找得到才跑真实推理。
  (cd "$IMG_DIR" && "$BIN" >/tmp/quiz-master2-yolo-run.log 2>&1 &)
  sleep 6
}
stop_app() {
  pkill -x quiz_master2 2>/dev/null || true
  sleep 1
  if [ -n "${XVFB_PID:-}" ]; then kill $XVFB_PID 2>/dev/null || true; fi
  sleep 1
  XVFB_PID=""
}
shot() { import -window root "$OUT_DIR/$1.png"; echo "截图已存：$OUT_DIR/$1.png"; }
click() { DISPLAY="$DISPLAY" xdotool mousemove --sync "$1" "$2" click --clearmodifiers 1; }

launch
shot e2e-01-home
click 75 127   # 左导航：收集中心
sleep 2
shot e2e-02-collect
click 770 127  # 导入学科下拉框
sleep 1
click 325 127  # 选数学
sleep 1
click 770 360  # 选择文件（垫片 zenity 返回测试图）
sleep 3
shot e2e-03-task-needbox
click 820 585  # 任务行：修框（真实检测约 4 秒，含首次模型加载）
sleep 10
shot e2e-04-editor-13-boxes
click 660 260  # 双击第一个题级框进内框模式
click 660 260
sleep 2
shot e2e-05-editor-inner-mode
DISPLAY="$DISPLAY" xdotool key Escape
sleep 1
click 810 576  # 取消（任务留修框中）
sleep 2
shot e2e-06-after-cancel
stop_app

# 恢复演示库：9 道题、3 学科、深色、启动页 home。
cp /tmp/qm2-demo-backup.db "$DB"
echo "演示库已恢复：$(python3 -c "
import sqlite3
c = sqlite3.connect('$DB')
print('questions=%d subjects=%d collect_tasks=%d' % (
  c.execute('select count(*) from questions').fetchone()[0],
  c.execute('select count(*) from subjects').fetchone()[0],
  c.execute('select count(*) from collect_tasks').fetchone()[0]))")"
echo "YOLO 端到端截图完成"
