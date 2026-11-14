#!/usr/bin/env bash
# P0B1-4 设置单 owner：复习页分页改 pageSize 与设置页失同步，改前 / 改后对照验证。
# 流程（深色、标准字号、1280×720，演示库 9 道题）：
#   复习页：每页下拉 10 → 20（库里 pageSize 当即变 20，两版都如此）；
#   设置页：打开「错题本」组看「每页显示数量」选中值——改前仍是 10（失同步），
#     改后是 20；再打开「外观」组点「浅色」换主题保存后查库——改前 pageSize
#     被旧快照全量写回成 10（覆盖），改后仍是 20。
# 用法：./run-shots-p0b1-settings.sh <before|after>
# 前置：两版 release 包已构建（改后：build/linux/x64/release/bundle；
#   改前：~/workspace/.p0b1-settings-before/bundle）。
# 每轮开始前从 /tmp/qm2-p0b1-orig.db 恢复演示库，结束后也恢复。
# 坐标按 1280×720 实测：复习导航 (100,260)；分页下拉 (570,507)，
# 菜单项 20 (568,497)；设置导航 (100,652)；错题本组头 (700,235)；
# 外观组头 (700,97)；主题「浅色」 (1113,153)。
set -euo pipefail

MODE="${1:-}"
if [ "$MODE" != before ] && [ "$MODE" != after ]; then
  echo "用法：$0 <before|after>"; exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ "$MODE" = before ]; then
  BIN="$HOME/workspace/.p0b1-settings-before/bundle/quiz_master2"
else
  BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
fi
DB="$HOME/.local/share/quiz-master2/quiz-master2.db"
BACKUP="/tmp/qm2-p0b1-orig.db"
OUT="$ROOT/docs/ui-replication/shots/p0b1-settings/$MODE"
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

"$BIN" >"/tmp/quiz-master2-p0b1-settings-$MODE.log" 2>&1 &
sleep 7

shot() { import -window root "$OUT/$1.png"; echo "[$MODE] $1"; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 2; }
dbcheck() { # $1 = 标签：把 pageSize / themeMode 写进对照记录
  {
    echo "== $1 =="
    echo "pageSize=$(sqlite3 "$DB" "select value from settings where key='pageSize';")"
    echo "themeMode=$(sqlite3 "$DB" "select value from settings where key='themeMode';")"
  } | tee -a "$OUT/db-checks.txt"
}
: > "$OUT/db-checks.txt"

shot 01-home
click 100 260; shot 02-review
click 570 507; sleep 1
click 568 497; shot 03-review-20
dbcheck '复习页改 10→20 后'
click 100 652; shot 04-settings
click 700 235; shot 05-settings-wrongbook
click 700 97; shot 06-settings-appearance
click 1113 153; shot 07-settings-light

pkill -x quiz_master2 || true
kill "$xvfb_pid" 2>/dev/null || true
sleep 1
dbcheck '设置页改主题为浅色、杀应用后'
cp "$BACKUP" "$DB"
echo "[$MODE] 完成，库已恢复原状"
