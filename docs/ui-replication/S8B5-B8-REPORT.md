# S8B5 / B8 确认报告

日期：2026-11-13。核对人：§8 接任协调员。两项均为只读核对，无代码改动。

## B5 已确认，无代码改动

**决定（Meng 2026-11-13 14:37 裁决）：本周 = 本周一到今天。**

核对结果：学习报告的“本周”实现已经是基线口径，无需改动。

- 位置：`lib/modules/report/report_page.dart:100-108`，`_rangeStart`：
  - `'week' => today.subtract(Duration(days: today.weekday - 1))`——`today.weekday` 周一为 1，减去 `weekday - 1` 天即本周一；范围终点是今天（`_inRange` 只判 `!d.isBefore(start)`，且数字按 `lastCheck` / `reviewedAt` 落在该区间内计）。
  - `'month' => DateTime(now.year, now.month, 1)`（当月 1 号到今天）；`'all' => null`（全部）。
- 页面范围说明（同文件约 118–127 行 `_rangeNote`）显示为“本周 · M-D ~ M-D · 数字按这个时间段算”，与实现一致。
- 文件头注释（约 30 行）已写明：“本周 = 本周一到今天（基线口径；HTML 是今天往前 7 天，见报告）”——HTML 的“今天往前 7 天”定义已被 Meng 否决，不采用。
- 三个核心数（已解决 / 待解决 / 复查通过率）按同一范围过滤，已在 B1 驗證通过（见 `S8B1-REPORT-PENDING-REPORT.md` §3）。

结论：**B5 已确认，无代码改动。**

## B8 已确认，无改动

**决定（Meng 2026-11-13 14:37 裁决）：关于页作者“Meng”确认无误。**

核对结果：关于页写的是作者 Meng，无需改动。

- 位置：`lib/modules/settings/settings_page.dart:1077`，`_kvRow('作者', 'Meng（个人项目）')`。
- 同文件约 25 行注释一致：“版本 v0.1.0、作者 Meng（个人项目）、更新说明”。

结论：**B8 已确认，无改动。**
