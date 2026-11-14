#!/usr/bin/env bash
# P0B1 错题本返回刷新：改前 / 改后对照验证。
# 流程（深色、标准字号、1280×720，演示库 9 道题）：
#   收藏：紧凑列表 → 定积分详情 → ☆ 收藏 → 返回 → （改后：视图被 _load
#     重置为大卡片，需再点一次「紧凑列表」）→ 星标应出现。
#   删除：定积分详情 → 删除 → 确认删除（删后自动进下一题）→ 返回 →
#     列表只剩函数极限，定积分消失。
# 归档与编辑不在本脚本里（删后列表行数在改前/改后不同，行坐标对不上），
# 改走交互验证，见 P0B1 报告。
# 用法：./run-shots-p0b1.sh <before|after>
# 前置：两版 release 包已构建（改后：build/linux/x64/release/bundle；
#   改前：~/workspace/.p0b1-before/build/linux/x64/release/bundle）。
# 每轮开始前从 /tmp/qm2-p0b1-orig.db 恢复演示库，结束后也恢复。
# 坐标按 1280×720 实测：错题本导航 (100,225)；数学封面 (430,330)；
# 「全部题目」行 (500,195)；「紧凑列表」切钮 (1035,163)；
# 紧凑行定积分 (450,225)；详情底部操作行（下滚 6 次后）返回 (190,653) /
# 收藏 (300,653) / 归档 (415,653) / 删除——收藏前 (785,653)，收藏后
# 按钮右移，删除约 (888,653)；删除确认框（再下滚 2 次后）确认删除
# (195,653)；详情顶部返回 (190,45)。
set -euo pipefail

MODE="${1:-}"
if [ "$MODE" != before ] && [ "$MODE" != after ]; then
  echo "用法：$0 <before|after>"; exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ "$MODE" = before ]; then
  BIN="$HOME/workspace/.p0b1-before/build/linux/x64/release/bundle/quiz_master2"
else
  BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
fi
DB="$HOME/.local/share/quiz-master2/quiz-master2.db"
BACKUP="/tmp/qm2-p0b1-orig.db"
OUT="$ROOT/docs/ui-replication/shots/p0b1-refresh/$MODE"
mkdir -p "$OUT"

cp "$BACKUP" "$DB"
echo "[$MODE] 库已恢复为演示库原状"

display_num=99
while [ -e "/tmp/.X${display_num}-lock" ]; do display_num=$((display_num + 1)); done
display=":$display_num"
export DISPLAY="$display"

Xvfb "$display" -screen 0 1280x720x24 >/dev/null 2>&1 &
xvfb_pid=$!
sleep 2

"$BIN" >"/tmp/quiz-master2-p0b1-$MODE.log" 2>&1 &
app_pid=$!
sleep 7

shot() { import -window root "$OUT/$1.png"; echo "[$MODE] $1"; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 2; }
scroll_down() { # $1 = 次数
  for _ in $(seq 1 "$1"); do xdotool mousemove 640 600 click 5; done
  sleep 2
}
scroll_top() {
  for _ in $(seq 1 10); do xdotool mousemove 640 600 click 4; done
  sleep 2
}

shot 01-home
click 100 225; shot 02-shelf
click 430 330; shot 03-directory
click 500 195; shot 04-list-large
click 1035 163; shot 05-compact-before
# --- 收藏：定积分（☆）→ 详情 → 收藏 → 返回 ---
click 450 225; shot 06-detail
scroll_down 6
click 300 653; shot 07-detail-favorited
click 190 653; shot 08-back-list
click 1035 163; shot 09-compact-after-fav
# --- 删除：定积分详情 → 删除 → 确认（自动进下一题）→ 返回 ---
click 450 225
scroll_down 6
# 注意：收藏后底部「☆ 收藏」变成宽按钮「★ 已收藏（点击取消）」，
# 后面的「下一题」「删除」整体右移：删除中心由 (785,653) 移到约 (888,653)；
# 用旧坐标会点中「下一题」（两轮首跑即因此走偏，已验证是脚本坐标问题，
# 不是应用 bug——行点击与删除本身在交互复核中均正常）。
click 888 653; shot 10-delete-confirm
scroll_down 2
click 195 653; sleep 2; shot 11-detail-after-delete
scroll_top
click 190 45; shot 12-list-after-delete

pkill -x quiz_master2 || true
kill "$xvfb_pid" 2>/dev/null || true
sleep 1
cp "$BACKUP" "$DB"
echo "[$MODE] 完成，库已恢复原状"
