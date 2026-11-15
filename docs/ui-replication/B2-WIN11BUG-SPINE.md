# B2 错题本封面书脊位置 — 修复报告（B2-WIN11BUG-SPINE）

- 日期：2026-11-14
- 分支：`ui-replication`（未 commit、未 push；不推代码）
- 范围：只改书脊（左侧深色竖条）的位置，改成图二的样子。折角、数字条/按钮、尺寸、颜色、虚线框、文字、数字一律不动。
- 对照：目标 `workspace/user/media_library/image/image-87.png`（书脊贴着封面左边缘）；对照 `image-86.png`（书脊离左边缘约 30px，归一化后）。

## 1. 根因（实测确认，不是猜的）

书脊代码原来就是 `Positioned(left: 0)`，但它不在封面盒子里——它在内层 `Stack` 里，而内层 `Stack` 在 `AnimatedContainer` 的内容内边距（左右 18、上 34、下 20）之内。所以 `left: 0` 实际落在**封面左缘内 18px**，且上下各短 34px/20px。

实测（第二批改后截图 `shots/b2-wrongbook-cover/after-light.png`，数学书体 x 246–556、顶 y=158）：
- 书脊暗带 x 264–273，即离左缘 **18px**，正好等于 `bookPaddingH`（18）；
- 书脊顶 y=192，即顶上短 **34px**，正好等于 `bookPaddingTop`（34）；
- 同一根因也解释了另外两处位置差（折角顶上短 34px、虚线内框偏里），但那两处 Meng 没让改，本次不动。

HTML 里书脊是相对整本书定位的（`.nb-book-spine{position:absolute;left:0;top:0;bottom:0;width:11px}`），Flutter 侧必须相对封面盒子定位才对得上。

## 2. 改动（只动 `lib/modules/wrongbook/wrongbook_page.dart`）

`_buildBook` 的封面改成两层 Stack：

- 外层 `Stack(clipBehavior: Clip.none)` 仍是 `AnimatedContainer` 的孩子（悬停上移 4px 的 transform 照常带上它）；内层 `ClipRRect > Stack`（纹样、虚线内框、书页边、折角、内容列）原封不动。
- 书脊用负偏移顶回封面边缘：`left: -bookPaddingH × scale`、`top: -bookPaddingTop × scale`、`bottom: -bookPaddingBottom × scale`、`width: 11 × scale`，自己的 `ClipRRect` 按封面左上角 6 / 左下角 12 的圆角裁剪。
- 内阴影左暗带必须跟着移到封面边缘，否则书脊移走后会在原位置（左缘内 18px）留下一条暗带，而且书脊颜色会变浅——实测书脊色 `(32,83,166)` 是黑 .20 叠加在暗带（黑 .18）上的结果，单画黑 .20 只有 `(38,99,197)`。所以 `_CoverInsetShadowPainter` 加了 `drawLeft` / `drawRight` 开关：左暗带用同一画笔在外层单独画（`drawRight: false`，宽 12 与画笔里的渐变宽一致），内层只留右亮带（`drawLeft: false`）。右亮带位置不动。

未动：折角、书页边、虚线内框、计数条、按钮、学科名/副标题、7 色、6 样式、悬停、`QmCoverMini`。书脊是三科共用的一套代码，改一次三本都变。

## 3. 验证

- `flutter analyze lib/modules/wrongbook/wrongbook_page.dart test/wrongbook_page_test.dart`：**0 问题**。
- `flutter test test/wrongbook_page_test.dart`：**43/43 通过**（基线 42 + 新增 1 项；只跑本文件，未跑全量——第三批同时在跑测试，避免互相干扰）。
- 新增回归测试「书脊贴着封面左边缘、通顶通底（与预览一致）」：三本书的书脊各贴各自封面的左缘、通顶通底、宽 11；内阴影画笔分两处用，共 6 个。旧测试「书架封面按预览画法」里内阴影画笔的断言由 3 个改为 6 个（画笔分两处是本次改动本身，不是回归）。
- 全量 analyze（整树）有 1 个 warning：`test/collect_page_test.dart:78` 的 `boxPages` 未用参数，是第三批正在改的文件，与本次无关。
- 截图：`docs/ui-replication/shots/b2-wrongbook-spine/after-light.png`（浅色；隔离树构建的 release 包 + `XDG_DATA_HOME` 指向工作区 scratch 库，live 库全程未动——见 §4）。

### 截图像素核对（数学书，与 image-87 同一套归一化方法：封面裁剪后缩到 600×720）

| 检查 | 改前（image-86） | 改后（本次截图） | 目标（image-87） |
|---|---|---|---|
| 书脊左缘 | 离封面左缘约 34px（归一化） | **0px，贴着左缘** | 约 5px（圆角抗锯齿，实为贴边） |
| 书脊宽 | 约 18px（归一化） | **约 18px** | 约 19px |
| 书脊色 | (32,83,166) | **(34,90,178)** | (34,88,175) |
| 书脊上下 | 顶上短 34px、底下被按钮盖住 | **通顶通底（y 0–714/720）** | 通顶通底 |
| 脊右 18px 处（旧位置） | 暗带 | **纯蓝，无残留暗带** | 纯蓝 |

- 英语（绿）、政治（红）同样验证：书脊各贴各自封面左缘，英语 x 588–597、政治 x 930–939，色值分别是 (21,104,67)、(148,54,51)，均为黑 .20 叠加暗带后的颜色，与改前同色、只换了位置。
- 折角、虚线内框、计数条、按钮在截图里与改前同一位置（本次没动它们；折角仍在旧位置，是 Meng 已知的第 1 处区别，另立项再定）。

## 4. 环境与 live 库

- 演示库是 v1（`~/.local/share/quiz-master2/quiz-master2.db`，9 题）。截图用的 scratch 库是 `/tmp/qm2-v2demo.db`（第二批做的 v1 副本按 v2 DDL 就地升级），`themeMode` 改为 light 以对照 image-87；应用通过 `XDG_DATA_HOME=~/workspace/spine-shot-data` 跑，live 库文件全程未被应用打开。
- 动手前 live 库已备份到工作区 `~/workspace/demo-db-backup-spine/quiz-master2.db`（md5 `8f7f9c64405dc6e484ac2bf8e5e1a807`，不要放 /tmp）。
- **中途发现 live 库被改过**：截图前核对发现 live 库 md5 变成了 `aff2242d…`（v2、0 题）——12:38 被 P1 的删旧库逻辑删库重建（当时我与第三批都在跑测试，`wrongbook_page_test` 的 FakeRepo 经 `super(AppDatabase.instance)` 打开真实单例，是已知 §4.1 隐患；第三批 P0-2 正在修的就是它）。已从工作区备份恢复，核对 md5 `8f7f9c64405dc6e484ac2bf8e5e1a807`、v1、9 题、3 学科，与开工前一致。
- 构建在隔离树 `~/workspace/qm2-spine-tree/`（复制当时工作树，不含 `build/`，`flutter build linux --release` 通过），避免与第三批在本树的构建争用；用完已删。截图脚本做法见第二批 `run-shots-b2-wrongbook-cover.sh`，本次改用 `XDG_DATA_HOME` 免换库。

## 5. 改动文件

- `lib/modules/wrongbook/wrongbook_page.dart`（`_buildBook` 外层 Stack + 书脊/左暗带移位、`_CoverInsetShadowPainter` 加开关）
- `test/wrongbook_page_test.dart`（新增书脊回归测试 1 项；旧测试内阴影画笔断言 3 → 6）
- `docs/ui-replication/B2-WIN11BUG-SPINE.md`（本报告）
- `docs/ui-replication/shots/b2-wrongbook-spine/after-light.png`（改后截图）
