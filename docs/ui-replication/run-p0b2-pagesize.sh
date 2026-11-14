#!/usr/bin/env bash
# P0B2 复习页“每页”下拉本地化：Linux 真机功能实测（不产截图）。
# 流程（深色、标准字号、1280×720，演示库 9 道题）：
#   复习页：每页下拉 10 → 20；随后进设置页开「错题本」组看默认值、
#   再进错题本看条数；全程查库 pageSize 应始终是 10。
# 用法：./run-p0b2-pagesize.sh
# 前置：release 包已构建（build/linux/x64/release/bundle）。
# 每轮开始前从 /tmp/qm2-p0b2-orig.db 恢复演示库，结束后也恢复。
# 坐标按 1280×720 实测（与 run-shots-p0b1-settings.sh 同布局）：
#   复习导航 (100,260)；分页下拉 (570,507)，菜单项 20 (568,497)；
#   设置导航 (100,652)；错题本组头 (700,235)；错题本导航 (100,225)；
#   数学封面 (430,330)；「全部题目」行 (500,195)。
# 临时自查截图只存 /tmp（确认下拉点中），看完即删，不进 shots/。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
DB="$HOME/.local/share/quiz-master2/quiz-master2.db"
BACKUP="/tmp/qm2-p0b2-orig.db"

cp "$BACKUP" "$DB"
echo "[p0b2] 库已恢复为演示库原状"

display_num=99
while [ -e "/tmp/.X${display_num}-lock" ]; do display_num=$((display_num + 1)); done
display=":$display_num"
export DISPLAY="$display"

Xvfb "$display" -screen 0 1280x720x24 >/dev/null 2>&1 &
xvfb_pid=$!
sleep 2

"$BIN" >"/tmp/quiz-master2-p0b2.log" 2>&1 &
sleep 7

click() { xdotool mousemove "$1" "$2" click 1; sleep 2; }
dbcheck() { # $1 = 标签
  echo "== $1 == pageSize=$(sqlite3 "$DB" "select value from settings where key='pageSize';") themeMode=$(sqlite3 "$DB" "select value from settings where key='themeMode';")"
}

dbcheck '开始前'
click 100 260
click 570 507; sleep 1
click 568 497
import -window root /tmp/qm2-p0b2-review20.png
dbcheck '复习页改 10→20 后'
click 100 652
click 700 235
import -window root /tmp/qm2-p0b2-settings.png
dbcheck '设置页开错题本组后'
click 100 225
click 430 330
click 500 195
import -window root /tmp/qm2-p0b2-wrongbook.png
dbcheck '错题本列表后'

pkill -x quiz_master2 || true
kill "$xvfb_pid" 2>/dev/null || true
sleep 1
dbcheck '杀应用后'
cp "$BACKUP" "$DB"
echo "[p0b2] 完成，库已恢复原状，md5=$(md5sum "$DB" | cut -d' ' -f1)"
