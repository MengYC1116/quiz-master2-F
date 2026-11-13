#!/usr/bin/env bash
# 一次性探针：打开报告 → 点“本月” → 向下滚 4 次 → 截图。
# 只用于定位“看更多”按钮，不进正式脚本。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
BIN="$ROOT/build/linux/x64/release/bundle/quiz_master2"
OUT="$ROOT/docs/ui-replication/shots/r9/probe-month-scrolled.png"
DB="$HOME/.local/share/quiz-master2/quiz-master2.db"
cp "$DB" /tmp/qm2-probe-m.db
restore() { cp /tmp/qm2-probe-m.db "$DB"; rm -f /tmp/qm2-probe-m.db; }
sqlite3 "$DB" "UPDATE settings SET value='light' WHERE key='themeMode'; UPDATE settings SET value='standard' WHERE key='fontSize';"
DISPLAY_NUM=96
while [ -e "/tmp/.X${DISPLAY_NUM}-lock" ]; do DISPLAY_NUM=$((DISPLAY_NUM + 1)); done
export DISPLAY=":$DISPLAY_NUM"
Xvfb "$DISPLAY" -screen 0 1280x720x24 >/dev/null 2>&1 &
XVFB_PID=$!
trap 'kill $APP_PID 2>/dev/null || true; kill $XVFB_PID 2>/dev/null || true; restore' EXIT
sleep 2
"$BIN" >/tmp/qm2-probe-m.log 2>&1 &
APP_PID=$!
sleep 5
xdotool mousemove 100 312 click 1; sleep 2
xdotool mousemove 344 88 click 1; sleep 2
for _ in 1 2 3 4; do xdotool mousemove 640 360 click 5; sleep 1; done
import -window root "$OUT"
echo "截图已存：$OUT"
