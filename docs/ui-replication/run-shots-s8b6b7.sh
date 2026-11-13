#!/usr/bin/env bash
# S8 B6 / B7 / 待定1 / 待定3 真机验证（复现用脚本）。
#
# 前置：演示库已备份到 /tmp/qm2-s8b6b7-orig.db（脚本结束时恢复）；
# 构建：flutter build linux --release；Xvfb 1280x720（:97）；
# 点按：xdotool 固定坐标（窗口 1280x720 下实测）；杀应用用 pkill -x quiz_master2。
# zenity 垫片见 /tmp/qm2-bin/zenity（本机 zenity 不支持 file_picker
# 要用的 --save；垫片只在本次验证的 PATH 里生效）。
#
# 各段是按顺序跑的（B7 收集导入 → B6 归档 → B7 整理确认 →
# 待定1 复查会话 → 待定3 备份失败），因为后一段依赖前一段的库状态
# 变化在截图里可见；每段也可单独跑，但跑完务必恢复演示库。
# 用法（分段跑，边看截图边确认坐标）：
#   ./run-shots-s8b6b7.sh b7        # B7：旧值读出 + 收集写入 + 整理写入
#   ./run-shots-s8b6b7.sh b6        # B6：归档 → 复习列表消失 → 取消归档 → 回来
#   ./run-shots-s8b6b7.sh leftover1 # 待定1：复查会话四步走完，solvedCount 不变
#   ./run-shots-s8b6b7.sh leftover3 # 待定3：备份失败 → 首页红横幅 → 知道了 → 重启不再出
#   ./run-shots-s8b6b7.sh restore  # 只恢复演示库
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
OUT="$ROOT/docs/ui-replication/shots/s8b6b7"
DB="$HOME/.local/share/quiz-master2/quiz-master2.db"
ORIG="/tmp/qm2-s8b6b7-orig.db"
PNG="$HOME/workspace/yolo-test-images/16676QPFVu1ck984AfWQHruoHWRfTz99b.png"
D=97
export DISPLAY=":$D"

for c in Xvfb import xdotool sqlite3; do
  command -v "$c" >/dev/null || { echo "未找到 $c"; exit 1; }
done
[ -x "$BIN" ] || { echo "找不到可执行文件：$BIN（先 flutter build linux --release）"; exit 1; }
mkdir -p "$OUT"

launch() {
  Xvfb "$DISPLAY" -screen 0 1280x720x24 >/dev/null 2>&1 &
  XVFB_PID=$!
  sleep 2
  "$BIN" >/tmp/quiz-master2-s8b6b7-run.log 2>&1 &
  sleep 6
}

stop_app() {
  pkill -x quiz_master2 2>/dev/null || true
  sleep 1
  kill $XVFB_PID 2>/dev/null || true
}

shot() { DISPLAY="$DISPLAY" import -window root "$OUT/$1"; }
click() { DISPLAY="$DISPLAY" xdotool mousemove --sync "$1" "$2" click --clearmodifiers 1; }

# zenity 垫片：--save 返回不存在的目录（待定3 写文件失败用）；
# 其余选择返回一张真实 PNG（B7 收集导入用）。
setup_shim() {
  mkdir -p /tmp/qm2-bin
  cat > /tmp/qm2-bin/zenity << SHIM_EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    --save) echo "/tmp/qm2-no-such-dir/quiz-master2-backup.json"; exit 0;;
    --directory) echo "\$HOME"; exit 0;;
  esac
done
echo "$PNG"
SHIM_EOF
  chmod +x /tmp/qm2-bin/zenity
  export PATH="/tmp/qm2-bin:$PATH"
}

restore_db() {
  pkill -x quiz_master2 2>/dev/null || true
  sleep 1
  cp "$ORIG" "$DB"
  rm -f "$DB-wal" "$DB-shm"
  echo "演示库已恢复："
  sqlite3 "$DB" "SELECT count(*) FROM questions; SELECT kind FROM recent_tasks;"
}

b7() {
  setup_shim
  # 旧英文值读出：库里 kind='collect'，首页应显示“收集中心”。
  sqlite3 "$DB" "UPDATE recent_tasks SET kind='collect', subject_id='math', title='函数极限';"
  launch
  shot 01-b7-legacy-collect-home.png
  # 收集写入：选数学 → 选择文件（垫片给 PNG）→ 任务出现、库里 kind='收集'。
  click 70 130; sleep 3
  click 750 130; sleep 1
  click 340 130; sleep 1
  click 750 360; sleep 8
  shot 06-b7-collect-imported.png
  click 70 85; sleep 3
  shot 07-b7-home-after-collect.png
  echo "recent_tasks 应为 收集："; sqlite3 "$DB" "SELECT kind FROM recent_tasks;"
  stop_app
}

b6() {
  # 归档一道已加入题（q-math-1 函数极限）→ 复习列表应只剩 2 组。
  sqlite3 "$DB" "UPDATE questions SET is_archived=1 WHERE id='q-math-1';"
  launch
  click 70 260; sleep 3
  shot 09-b6-archived-review.png
  stop_app
  # 取消归档 → 重新出现（单独跑本段时回到 3 组；报告里的 12 号图
  # 是先跑过 B7 整理确认的库，多了政治待治组，共 4 组）。
  sqlite3 "$DB" "UPDATE questions SET is_archived=0 WHERE id='q-math-1';"
  launch
  click 70 260; sleep 3
  shot 12-b6-unarchived-review.png
  stop_app
}

leftover1() {
  # 复查会话：英语 概念不清组（q-eng-1，已解决 2 次、复查到期）的
  # 开始解决 → 四步走完 → 自查“已解决” → 下一题；查库 solvedCount 应仍为 2。
  launch
  click 70 260; sleep 3
  click 1065 363; sleep 3
  shot 13-leftover1-session-recall.png
  click 675 517; sleep 2   # 下一步：写补救
  shot 14-leftover1-session-remedy.png
  click 682 350; sleep 2   # 下一步：重做
  shot 15-leftover1-session-redo.png
  click 748 430; sleep 2   # 看答案
  shot 16-leftover1-session-redo-shown.png
  click 688 542; sleep 2   # 下一步：自查
  shot 17-leftover1-session-check.png
  click 421 258; sleep 1   # 自查选“已解决”
  click 728 331; sleep 2   # 下一题（本轮共 4 块，未到末块所以不是“看总结”）
  shot 18-leftover1-advanced-next-block.png
  click 903 72; sleep 3    # 暂停，回列表
  shot 19-leftover1-after-recheck.png
  echo "q-eng-1 应仍为 solved / 2 / 复查日顺延："
  sqlite3 "$DB" "SELECT status, solved_count, recheck_date FROM cause_records WHERE question_id='q-eng-1';"
  stop_app
}

leftover3() {
  setup_shim
  launch
  click 70 660; sleep 3    # 设置
  click 750 302; sleep 2   # 展开“数据”组
  click 1170 357; sleep 3  # 备份题库（垫片给不存在的目录，写失败）
  shot 22-leftover3-backup-failed-snack.png
  echo "标志应为 1："; sqlite3 "$DB" "SELECT value FROM settings WHERE key='backupFailed';"
  click 70 85; sleep 3     # 首页：红横幅
  shot 23-leftover3-home-banner.png
  click 1171 141; sleep 2  # 知道了
  shot 24-leftover3-home-dismissed.png
  echo "标志应为 0："; sqlite3 "$DB" "SELECT value FROM settings WHERE key='backupFailed';"
  stop_app
  launch                   # 重启：横幅不再出现
  shot 25-leftover3-home-after-restart.png
  stop_app
}

case "${1:-}" in
  b7) b7 ;;
  b6) b6 ;;
  leftover1) leftover1 ;;
  leftover3) leftover3 ;;
  restore) restore_db ;;
  *) echo "用法：$0 {b7|b6|leftover1|leftover3|restore}"; exit 1 ;;
esac
