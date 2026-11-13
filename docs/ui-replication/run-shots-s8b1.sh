#!/usr/bin/env bash
# S8 B1 截图脚手架：在 Xvfb 下以 1280×720 运行 quiz-master2（Linux Release
# 构建产物），截报告页本周/本月/全部三档（深色标准字号），存入
# docs/ui-replication/shots/s8b1/。
#
# 为让三档数字可区分，临时改两条待解决记录的 last_check（拍完用备份恢复）：
#   q-pol-1 审题失误 -> 2026-11-08 10:00（本月内、本周外）
#   q-pol-3 方法不会 -> 2026-10-04 10:00（本月外）
# 其余记录不动：q-math-3 解决中 lastCheck 2026-11-11（本周内），
# q-eng-1 已解决 lastCheck 2026-11-11（本周内），另 3 条待解决 lastCheck
# 为空（按 B1 口径计入所有范围）。
# 预期核心数（已解决 / 待解决 / 通过率）：本周 1 / 4 / —，
# 本月 1 / 5 / —，全部 1 / 6 / —。
#
# 用法：
#   ./run-shots-s8b1.sh probe    # 只截探针图（校准分段控件坐标）
#   ./run-shots-s8b1.sh          # 三档全截
#
# 实现：改库前整库备份到工作区根目录 .qm2-s8b1-backup.db，跑完用备份
# 文件恢复并删除备份。主题与字号走 settings 表（原库已是 dark/standard）。
# 前置：已跑过 flutter build linux --release。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
OUT_DIR="$ROOT/docs/ui-replication/shots/s8b1"
DB="$HOME/.local/share/quiz-master2/quiz-master2.db"
BACKUP="$ROOT/.qm2-s8b1-backup.db"

[ -x "$BIN" ] || { echo "找不到可执行文件：$BIN"; echo "请先跑 flutter build linux --release"; exit 1; }
command -v Xvfb >/dev/null || { echo "未找到 Xvfb"; exit 1; }
command -v import >/dev/null || { echo "未找到 ImageMagick import"; exit 1; }
command -v sqlite3 >/dev/null || { echo "未找到 sqlite3"; exit 1; }
command -v xdotool >/dev/null || { echo "未找到 xdotool"; exit 1; }

mkdir -p "$OUT_DIR"

cp "$DB" "$BACKUP"
echo "原库已备份到 $BACKUP"

restore() {
  cp "$BACKUP" "$DB"
  rm -f "$BACKUP"
  echo "库已恢复，备份已删除"
}
trap restore EXIT

# 临时改两条 last_check（毫秒 epoch）。
TS_IN_MONTH=$(( $(date -d '2026-11-08 10:00:00' +%s) * 1000 ))
TS_OUT_MONTH=$(( $(date -d '2026-10-04 10:00:00' +%s) * 1000 ))
sqlite3 "$DB" "UPDATE cause_records SET last_check=$TS_IN_MONTH WHERE question_id='q-pol-1'; UPDATE cause_records SET last_check=$TS_OUT_MONTH WHERE question_id='q-pol-3';"
echo "已临时改 last_check：q-pol-1 -> 2026-11-08，q-pol-3 -> 2026-10-04"
sqlite3 "$DB" "SELECT question_id, cause, status, last_check FROM cause_records ORDER BY question_id;"

launch() {
  local display_num=99
  while [ -e "/tmp/.X${display_num}-lock" ]; do display_num=$((display_num + 1)); done
  DISPLAY=":$display_num"
  export DISPLAY
  Xvfb "$DISPLAY" -screen 0 1280x720x24 >/dev/null 2>&1 &
  XVFB_PID=$!
  sleep 2
  "$BIN" >/tmp/quiz-master2-s8b1-run.log 2>&1 &
  sleep 5
}

stop_app() {
  pkill -x quiz_master2 2>/dev/null || true
  sleep 1
  kill $XVFB_PID 2>/dev/null || true
}

click() { xdotool mousemove "$1" "$2" click 1; sleep 2; }
shot() { import -window root "$OUT_DIR/$1.png"; echo "截图已存：$OUT_DIR/$1.png"; }

# 导航“学习报告”Y（标准字号 1280×720，R9 探针校准）。
go_report() { click 100 312; }

if [ $# -eq 1 ] && [ "$1" = "probe" ]; then
  launch
  go_report
  shot probe-report-dark-standard
  stop_app
  exit 0
fi

launch
go_report
shot report-week-dark-standard
# 分段控件（y=88；探针图像素扫描实测：“本月”文字中心 x≈350，
# “全部”文字中心 x≈417；R9 的 344 亦落在“本月”文字内）。
click 350 88
shot report-month-dark-standard
click 417 88
shot report-all-dark-standard
stop_app

echo "三档截图完成，库已恢复（trap）"
