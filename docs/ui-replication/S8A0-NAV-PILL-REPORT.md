# S8A0 — §8.1 #2 核实：深色导航选中项纯白 pill 是否已解决

- 任务：核实 0d9d15d（选中态四层 InkWell 反馈色全改 accent）是否彻底解决
  R11 §8.1 #2；亮色已在 Win11 bugfix 会话中像素验证通过，本次补深色真机验证。
- 分支：`ui-replication`，head `0d9d15d`；构建：Linux Release（`/usr/local/quiz_master2`，
  libapp.so 与工作树一致）；环境：Xvfb 1280×720，演示库（themeMode=dark）。

## 验证方法

全新启动应用（深色）→ 点左导航「复习」（导航动作）→ 鼠标停在选中项上 2 秒 →
截图并对 pill 区域逐像素采样；同法复核「学科管理」。

## 结果：通过，已解决

| 选中项（鼠标停在上面，导航点击后 2 秒） | 像素采样主色 | 结论 |
|---|---|---|
| 复习 | `#7FA8D0` (127,168,208)，711 采样 | 深色 accent，正确 |
| 学科管理 | `#7FA8D0` (127,168,208)，666 采样 | 深色 accent，正确 |

- 两张截图中均无纯白 `(255,255,255)` 像素进入主色统计；目视 pill 为浅蓝底深字。
- 与亮色验证（bugfix 会话：导航点击后选中 pill 保持 `#2E7CF6`）合起来，
  亮/深两态均已证实：导航后鼠标停在选中项上不再变纯黑/纯白。
- 截图：`docs/ui-replication/shots/s8a0/nav-review-dark-hover.png`、
  `docs/ui-replication/shots/s8a0/nav-subjects-dark-hover.png`。

## 结论

R11 §8.1 #2 标记**已解决**（0d9d15d）。根因回顾：导航重建时 InkWell 悬停遮罩
按当前 hoverColor 重画，真机渲染里遮罩 alpha 被忽略、按 RGB 不透明画出；
0d9d15d 把选中态 hover/splash/highlight/focus 四层反馈色全取 accent 本身，
任何渲染路径下都是 accent 色。回归测试 `test/nav_hover_regression_test.dart`
（亮/深/折叠三态）已覆盖，`flutter test` 279/279 通过。
