#!/usr/bin/env bash
# P0B2-3 左导航 + 调色板：Linux 真机功能实测（不产截图到仓库）。
# 流程（深色、标准字号、1280×720，演示库 9 道题）：
#   学科管理 → 展开「学科」段 → 连加 7 科（物理/化学/生物/历史/地理/
#   语文/外语）→ 查库：7 科颜色应为蓝/绿/红/紫/橙/青/粉（演示库三科
#   是 R1 前的旧色，不占新轮换表，所以第 1 科新学科拿新蓝）；
#   左导航 10 科时设置仍在首屏底部可点 → 点设置进设置页；
#   滚轮下滚速览区：第 5 行出现、设置不动。
# 用法：./run-p0b2-nav-palette.sh
# 前置：release 包已构建（build/linux/x64/release/bundle）。
# 备份 /tmp/qm2-p0b2-nav-orig.db 首次运行时从 live 库生成（须是演示库
# 原状：9 题、3 科、深色、pageSize=10），每轮开始与结束后都从它恢复。
# 坐标按 1280×720 实测：学科管理导航 (100,342)；学科段头 (700,97)；
# 新学科输入框 (700,146)；＋ 添加学科 (1177,146)；设置导航 (100,672)；
# 速览滚动区 (100,550)。
# 注意：xdotool type 打不出中文，改用 key Uxxxx 逐字敲；两字之间 sleep
# 0.5s，丢键率低（实测中「化学」曾丢成「化」，颜色不受影响，重跑即可）。
# 临时自查截图只存 /tmp，看完即删，不进 shots/。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
DB="$HOME/.local/share/quiz-master2/quiz-master2.db"
BACKUP="/tmp/qm2-p0b2-nav-orig.db"

if [ ! -f "$BACKUP" ]; then
  cp "$DB" "$BACKUP"
  echo "[p0b2-nav] 备份已从 live 库生成：$BACKUP"
fi
cp "$BACKUP" "$DB"
echo "[p0b2-nav] 库已恢复为演示库原状"

display_num=99
while [ -e "/tmp/.X${display_num}-lock" ]; do display_num=$((display_num + 1)); done
display=":$display_num"
export DISPLAY="$display"

Xvfb "$display" -screen 0 1280x720x24 >/dev/null 2>&1 &
xvfb_pid=$!
sleep 2

"$BIN" >"/tmp/quiz-master2-p0b2-nav.log" 2>&1 &
sleep 7

click() { xdotool mousemove "$1" "$2" click 1; sleep 2; }
dbcheck() { # $1 = 标签
  echo "== $1 =="
  sqlite3 "$DB" "select name,printf('%x',color) from subjects;"
  echo "demo_questions=$(sqlite3 "$DB" "select count(*) from questions where is_demo=1;") themeMode=$(sqlite3 "$DB" "select value from settings where key='themeMode';") pageSize=$(sqlite3 "$DB" "select value from settings where key='pageSize';")"
}
add_subject() { # $1 $2 = 两字 unicode 码点，如 U7269 U7406（物理）
  click 700 146
  xdotool key "$1"; sleep 0.5
  xdotool key "$2"; sleep 1
  click 1177 146
}

dbcheck '开始前'
click 100 342
click 700 97
add_subject U7269 U7406   # 物理 → 新蓝 ff2e7cf6
add_subject U5316 U5B66   # 化学 → 新绿 ff00a884
add_subject U751F U7269   # 生物 → 新红 ffef4444
add_subject U5386 U53F2   # 历史 → 紫 ff7c5cfc
add_subject U5730 U7406   # 地理 → 橙 fff08a1d
add_subject U8BED U6587   # 语文 → 青 ff06b6d4
add_subject U5916 U8BED   # 外语 → 粉 ffec4899
dbcheck '加 7 科后'
import -window root /tmp/qm2-p0b2-nav-10subjects.png

# 设置在 10 科时仍在首屏底部：点它进设置页。
click 100 672
import -window root /tmp/qm2-p0b2-nav-settings.png
dbcheck '点设置进设置页后'

# 速览区内部滚动：滚轮下滚，第 5 行出现、设置不动。
for _ in 1 2 3 4 5 6; do xdotool mousemove 100 550 click 5; sleep 0.3; done
sleep 1
import -window root /tmp/qm2-p0b2-nav-scrolled.png

pkill -x quiz_master2 || true
kill "$xvfb_pid" 2>/dev/null || true
sleep 1
cp "$BACKUP" "$DB"
echo "[p0b2-nav] 完成，库已恢复原状，md5=$(md5sum "$DB" | cut -d' ' -f1)"
dbcheck '恢复后'
