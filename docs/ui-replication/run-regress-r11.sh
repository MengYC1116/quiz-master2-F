#!/usr/bin/env bash
# R11 最终验收导航回归：九页全链路（首页 → 收集 → 整理 → 错题本
# 书架 → 目录 → 列表 → 详情 → 返回列表 → 复习 → 报告 → 学科管理
# → 设置 → 回首页），亮色与深色各一遍，截图存入
# docs/ui-replication/shots/r11/regress-{dark,light}/。
#
# 用法：./run-regress-r11.sh
# 前置：已跑过 flutter build linux --release；DB 为演示库（9 道题），
# 截图前整库备份到 /tmp/qm2-r11-regress-orig.db，跑完恢复原库与原设置
# （themeMode=dark / fontSize=standard）。
# 点击坐标按标准字号 1280×720 像素扫描实测（R2–R10 各轮一致）：
# 导航 首页 100 / 收集 139 / 整理 182 / 错题本 225 / 复习 271 /
# 学习报告 312 / 学科管理 353 / 设置 667；数学书封中心约 (430,400)；
# “全部题目”行 (500,310)；列表首卡 (640,300)；详情返回 (190,45)。
# 本回归只读跳转（不点任何写操作按钮），结束时恢复数据库。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
DB="$HOME/.local/share/quiz-master2/quiz-master2.db"
BACKUP="/tmp/qm2-r11-regress-orig.db"

cp "$DB" "$BACKUP"
echo "库已备份：$BACKUP"

run_tour() {
  local theme="$1"   # dark | light
  local out="$ROOT/docs/ui-replication/shots/r11/regress-$theme"
  mkdir -p "$out"

  sqlite3 "$DB" "UPDATE settings SET value='$theme' WHERE key='themeMode';"

  local display_num=99
  while [ -e "/tmp/.X${display_num}-lock" ]; do display_num=$((display_num + 1)); done
  local display=":$display_num"
  export DISPLAY="$display"

  Xvfb "$display" -screen 0 1280x720x24 >/dev/null 2>&1 &
  local xvfb_pid=$!
  sleep 2

  "$BIN" >"/tmp/quiz-master2-r11-regress-$theme.log" 2>&1 &
  local app_pid=$!
  sleep 5

  shot() { import -window root "$out/$1.png"; echo "[$theme] 截图已存：$out/$1.png"; }
  click() { xdotool mousemove "$1" "$2" click 1; sleep 2; }

  shot 01-home
  click 100 139; shot 02-collect
  click 100 182; shot 03-organize
  click 100 225; shot 04-wrongbook-shelf
  click 430 400; shot 05-wrongbook-directory
  click 500 310; shot 06-wrongbook-list
  click 640 300; shot 07-detail
  click 190 45;  shot 08-back-list
  click 100 271; shot 09-review
  click 100 312; shot 10-report
  click 100 353; shot 11-subjects
  click 100 667; shot 12-settings
  click 100 100; shot 13-back-home

  kill "$app_pid" 2>/dev/null || true
  kill "$xvfb_pid" 2>/dev/null || true
  sleep 1
}

run_tour dark
run_tour light

cp "$BACKUP" "$DB"
echo "库已恢复原状（themeMode/fontSize 回到备份值）"
sqlite3 "$DB" "SELECT key, value FROM settings WHERE key IN ('themeMode','fontSize');"
echo "R11 回归完成"
