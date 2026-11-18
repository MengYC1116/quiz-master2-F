# 十三批 P1 修复回归报告

- 日期：2026-11-18（子代理，P1 修复回归工）
- 范围：只修 P1 修复后全量回归的 4 项测试失败 + Linux Release 构建失败。未推送代码；未给 Meng 发邮件/消息；未改 `docs/decision-log.md`（D-115 条目草稿见 §6，请统筹追加）。
- 结论：**4 项失败全部是测试侧问题，产品行为无退化，生产代码零改动**——只改 2 个测试文件。构建失败是本机环境丢了 `libgtk-3-dev`，apt 重装恢复。
- 演示库：跑全量前复用已有备份 `~/workspace/demo-db-backup/quiz-master2.db.b13-p1fix-start`（备份前核对：与现库 md5 一致）；跑后 `~/.local/share/quiz-master2/quiz-master2.db` md5 仍为 `8f7f9c64405dc6e484ac2bf8e5e1a807`，不变。
- 全量日志：`~/workspace/batch13-work/p1fix-full-test-2.log`（上一轮失败日志为 `p1fix-full-test.log`）。

## 1. 四项失败的根因（逐项）

### 1. SR3-10 切片自愈（`test/detail_notifier_test.dart:807`）——测试过时

- 现象：`Expected <492>，Actual <560>`——断言自愈后 `slices/q1.png` 宽 492，实际仍是 560。
- 根因：测试写死了 P1-1 之前的**原地覆盖**行为。P1-1 后自愈是不可变切片：文件存在但尺寸不符时写**版本化新文件**（`slices/q1-v<时间戳>-<随机>.png`），库里 `slice_path` 指过去，**旧文件字节永不动**。自愈本身是成功的——轮询 `repo.saved` 里 `sliceWidth == 492` 已通过，失败的只是随后对旧文件的断言。
- 定性：产品行为正确，测试断言过时。**未改回原地覆盖。**
- 修法（只改测试）：断言新文件 492×280（从 `savedQ.slicePath` 取版本化路径），并反向断言旧文件字节与写入前逐字节相同（仍是 560×700 页图）。

### 2. SR-P2-3 详情页重框事务失败不留孤儿切片（`test/b5_p2_collect_test.dart:869`）——测试过时

- 现象：断言事务失败后 `slices/q1.png` 不存在，实际存在。
- 根因分两层：
  1. 测试写死了旧行为：旧写法里重框新切片就是 `slices/q1.png` 本身（原地覆盖），事务失败时删它；P1-1 后新切片走**临时文件 → 版本化新路径 rename**，事务失败时 catch 只删临时文件，版本化目标根本没建出来——没有新文件可删，也没有孤儿。
  2. `slices/q1.png` 之所以存在，是**详情页打开时自愈的缺失文件分支**：用例里库里记了 `slices/q1.png` 但文件不存在，`load()` 触发的 `_healSliceIfNeeded` 按当前框重裁、**首写**到库里记的路径。这是库里记的现行切片，事务失败绝不能删——删了就是 P1-1 要堵的 SR2-3 丢图 bug 的重演。
- 定性：产品行为正确（临时文件已删、现行切片完好、框与题不动），测试断言过时。**未改回原地覆盖。**
- 修法（只改测试）：用例开头先在 `slices/` 预摆一张与库里尺寸相符（200×100）的旧切片——自愈见尺寸相符直接返回，本用例只测重框事务失败这一条路径；断言改为旧切片字节完好 + 无 `-v` 版本化文件、无 `.tmp-` 临时文件残留；`repo.saved` 为空、失败提示、框与题不动的原断言保留不变。

### 3&4. SR-P2-22 收集页确认失败不留孤儿文件 ×2（`test/b5_p2_collect_test.dart:962`，裁剪失败与事务失败两个子用例）——测试串扰，生产清理正常

- 现象：`expectCleanedUp`（`slices/` 为空断言）返回 false。
- 根因：**跨用例串扰，不是确认清理坏了**。`b5_p2_collect_test.dart` 的 `_testTmp` 是 `setUpAll` 建的、**全文件共享**；排在前面的 SR-P2-3 用例里自愈写出的 `slices/q1.png` 留在了共享目录里，SR-P2-22 的 `expectCleanedUp` 断言整个 `slices/` 为空，于是失败。
- 证据：两个子用例**单跑全部通过**（`--plain-name` 各自过滤单跑均 `All tests passed`），生产清理路径（`CollectNotifier.confirmSplit` 的 `writtenRels` 清单 + 失败分支 `_deleteWrittenFiles`）工作正常——第 1 页已写的切片与烘焙图确实被清掉了。
- 定性：产品行为正确；失败是 SR-P2-3 用例没清理自己写的文件。**`expectCleanedUp` 本身未动**（全目录为空仍是确认清理的有效强断言）。
- 修法（只改测试）：SR-P2-3 用例加 `addTearDown`，结束后删掉自己写的 `slices/` 目录。

## 2. 改动文件清单（仅 2 个测试文件，生产代码零改动）

| 文件 | 改动 |
|---|---|
| `test/detail_notifier_test.dart` | SR3-10 自愈测试改新行为断言：新版本化文件 492×280、旧文件字节不变 |
| `test/b5_p2_collect_test.dart` | `setUpAll` 加 200×100 旧切片夹具（`_slicePngPath`）；SR-P2-3 预摆尺寸相符旧切片 + 新断言（旧切片完好、无 `-v`/`.tmp-` 残留）+ `addTearDown` 清理 `slices/`（同时修掉 3&4 号失败的串扰源） |

## 3. 构建环境修复（只动本机环境，不改仓库代码）

- 故障：`flutter build linux --release` 在 CMake 阶段失败，`PkgConfig::GTK` 找不到 `/usr/include/gtk-3.0`；`dpkg` 查不到 `libgtk-3-dev`（M7 时构建是通过的，P1-2 回归期间一次服务重启 + apt 折腾后丢的）。
- 修复：`apt-get install -y --allow-downgrades libgtk-3-dev libzstd1=1.5.5+dfsg2-2build1.1`，装好 `libgtk-3-dev 3.24.41`（`pkg-config --modversion gtk+-3.0` = `3.24.41`），构建恢复。
- 中途两道坎：
  1. `apt-get update` 跑了约 12 分钟才完：azure 镜像本身正常（curl 秒回 200），但 `lists/partial` 攒到 223MB 才走完，且 cogentco 镜像一条索引拉取失败（`Connection failed [IP: 198.19.0.1 3128]`），仅警告、用了旧索引，不影响安装。
  2. **版本冲突**：`libzstd-dev` 要求 `libzstd1 = 1.5.5+dfsg2-2build1.1`，但本机装的是 `1.5.5+dfsg2-2build1.1+hatch1`（候选也是它）。光加 `--allow-downgrades` 不解析；光指定版本时 apt 虽算出降级方案却因 `-y` 没带 `--allow-downgrades` 而拒绝。两者结合才装上：`libzstd1` 降级到发行版 `1.5.5+dfsg2-2build1.1`（与 M7 同款处理），另装 `libgdk-pixbuf-2.0-dev`、`libtiff-dev`、`libzstd-dev`。
- 注意：`libzstd1` 的 `+hatch1` 版如被镜像机制重新装回，下次构建会再次遇到同款冲突。

## 4. 验证结果

测试环境：`TMPDIR=$HOME/workspace/flutter-test-tmp`，`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`。

### 4.1 失败文件复跑（修后）

| 文件 | 结果 |
|---|---|
| `test/detail_notifier_test.dart` + `test/b5_p2_collect_test.dart` 一次跑完 | **全部通过**（`All tests passed!`） |

### 4.2 全量（`flutter test --concurrency=1`）

- **1690/1690 通过，0 失败**（上一轮 1686 通过 + 4 失败；本次测试总数不变，只改了断言）
- 4 个原失败用例在全量中全部通过（日志行 1869、1916–1918）
- 日志：`~/workspace/batch13-work/p1fix-full-test-2.log`（`12:12 +1690: All tests passed!`）

### 4.3 其余验证

| 项 | 结果 |
|---|---|
| `flutter analyze`（全仓） | **No issues found**（`ANALYZE_EXIT=0`） |
| Linux Release 构建（`flutter build linux --release`） | **成功**，`build/linux/x64/release/bundle/quiz_master2`（`BUILD_EXIT=0`） |
| 演示库 md5 | 跑前备份复用 `~/workspace/demo-db-backup/quiz-master2.db.b13-p1fix-start`（与现库 md5 一致）；跑后 `~/.local/share/quiz-master2/quiz-master2.db` 仍为 `8f7f9c64405dc6e484ac2bf8e5e1a807`，不变 |

## 5. 遗留问题

1. **共享 `_testTmp` 的串扰土壤还在**：`b5_p2_collect_test.dart` 的临时目录是 `setUpAll` 全文件共享的，任何用例在 `slices/` 留文件都会让 SR-P2-22 的全目录断言失败。本次只修了 SR-P2-3 这一处；后续用例若再写 `slices/` 须自带 `tearDown` 清理，或把 `expectCleanedUp` 改为只断言本次确认写的文件。
2. **`libzstd1` 版本冲突是复发隐患**：`+hatch1` 版与 `libzstd-dev` 冲突，见 §3；如下次 apt 又把它升回去，构建会再次失败，同款命令可解。
3. 本次未推送代码，未给 Meng 发邮件/消息；`docs/decision-log.md` 未改。
4. 未验证 Win11 真机。

## 6. D-115 条目草稿（请统筹追加到 docs/decision-log.md）

> **D-115（十三批 P1 修复回归，2026-11-18）**：P1-1 不可变切片后的全量回归 4 项失败全部是测试侧问题，生产代码零改动——(1) SR3-10 自愈测试改断言新行为：自愈写版本化新文件（`slices/<id>-v<时间戳>-<随机>.png`），旧文件字节永不动；(2) SR-P2-3 重框事务失败测试：详情页打开时自愈（缺失文件分支）已首写出库里记的现行切片，事务失败只删临时文件、绝不删现行切片（否则重演 SR2-3 丢图 bug），测试预摆尺寸相符旧切片、断言旧切片完好且无 `-v`/`.tmp-` 残留；(3)(4) SR-P2-22 两项是共享 `_testTmp` 串扰：SR-P2-3 残留的自愈切片让 `slices/` 为空断言失败，生产清理（`writtenRels` 清单）单跑验证正常，修复为 SR-P2-3 自带 `tearDown` 清理。构建环境：`libgtk-3-dev` 重装（3.24.41），`libzstd1` 须显式降级到发行版 `1.5.5+dfsg2-2build1.1`（`+hatch1` 版与 `libzstd-dev` 冲突，`--allow-downgrades` 单独不解析）。验证：全量 1690/1690、analyze 0 问题、Linux Release 构建成功、演示库 md5 不变。
