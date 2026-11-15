#!/usr/bin/env bash
# B2 错题本书架封面：改前/改后截图（亮色 + 深色 + 斜纹黄组合 + 悬停）。
# 用法：./run-shots-b2-wrongbook-cover.sh before|after
# 前置：已跑过 flutter build linux --release；DB 为演示库（9 道题）。
# 每轮开始前从备份恢复整库、只改本轮要的 themeMode / 封面样式，
# 结束恢复原库（themeMode=dark / fontSize=standard）。
# 点击坐标按标准字号 1280×720 实测（R11 回归脚本同一套）：
# 左导航 错题本 (100,225)；数学书封中心约 (430,400)。
# 只读跳转 + 悬停，不点任何写操作按钮；清理只 kill 存下的 PID，
# 不用 pkill -f 匹配（曾自匹配杀掉执行 shell、导致库恢复被跳过）。
set -euo pipefail

TAG="${1:-before}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# B2_BIN：要截图的二进制（默认本树 release 包；改前对比可用隔离树产物）。
BIN="${B2_BIN:-$ROOT/build/linux/x64/release/bundle/quiz_master2}"
DB="$HOME/.local/share/quiz-master2/quiz-master2.db"
BACKUP="/tmp/qm2-b2-cover-shots-orig.db"
# B2_DEMO：每轮开始前装到 live 位置的库（默认 v1 原库备份；
# 用迁移后的 v2 演示库 /tmp/qm2-v2demo.db 时，封面带真实计数 + 深色生效）。
DEMO="${B2_DEMO:-$BACKUP}"
OUT="$ROOT/docs/ui-replication/shots/b2-wrongbook-cover"
mkdir -p "$OUT"

cp "$DB" "$BACKUP"
echo "库已备份：$BACKUP"

run_tour() {
  local theme="$1"   # dark | light
  local name="$2"    # dark | light | combo-dark | hover-dark
  local combo="$3"   # 0 | 1（数学改斜纹黄封面，验易显脏组合）

  cp "$DEMO" "$DB"
  sqlite3 "$DB" "UPDATE settings SET value='$theme' WHERE key='themeMode';"
  if [ "$combo" = "1" ]; then
    sqlite3 "$DB" "UPDATE subjects SET cover_style='diagonal', cover_color='yellow' WHERE id='math';"
  fi

  local display_num=99
  while [ -e "/tmp/.X${display_num}-lock" ]; do display_num=$((display_num + 1)); done
  local display=":$display_num"
  export DISPLAY="$display"

  Xvfb "$display" -screen 0 1280x720x24 >/dev/null 2>&1 &
  local xvfb_pid=$!
  sleep 2

  "$BIN" >"/tmp/quiz-master2-b2-cover-$TAG-$name.log" 2>&1 &
  local app_pid=$!
  sleep 5

  xdotool mousemove 100 225 click 1
  sleep 2
  import -window root "$OUT/$TAG-$name.png"
  echo "[$TAG-$name] 截图已存：$OUT/$TAG-$name.png"

  if [ "$name" = "hover-dark" ]; then
    xdotool mousemove 430 400
    sleep 1
    import -window root "$OUT/$TAG-$name.png"
    echo "[$TAG-$name] 悬停截图已存（覆盖上一张同名书架图）"
  fi

  kill "$app_pid" 2>/dev/null || true
  kill "$xvfb_pid" 2>/dev/null || true
  sleep 1
}

run_tour dark dark 0
run_tour light light 0
run_tour dark combo-dark 1
run_tour dark hover-dark 0

cp "$BACKUP" "$DB"
echo "库已恢复原状（v1 原库）"
sqlite3 "$DB" "SELECT id,cover_color,cover_style FROM subjects; SELECT key,value FROM settings WHERE key='themeMode';"
echo "原库 md5 应为 8f7f9c64405dc6e484ac2bf8e5e1a807："
md5sum "$DB" "$BACKUP"
echo "B2 封面截图完成：$TAG（BIN=$BIN DEMO=$DEMO）"
