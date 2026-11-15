# B10-1 远端残留孤儿文件清理报告（P0-1）

- 日期：2026-11-15（CST 22:24，UTC 14:24）
- 仓库：MengYC1116/quiz-master2-F，分支 `ui-replication`
- 执行方式：GitHub 连接器 `delete_file`（每次删除一次单独提交，均经审批卡批准后执行）
- 本项不改本地代码、不 commit、不推代码；本地树仅新增本报告文件。

## 1. 背景

B8-2 在本地删掉的 3 个二层测试，远端 `ui-replication` 还留着，因为快照推送删不了文件。
本地树里这 3 个文件不存在（B8-2 已删），这就是那棵树 analyze 48 个错、899 无法复现的原因。

删除前远端 head：`6316a230947aa99d5e01173eff49eaec58fe95bc`
（"Batch 9: collect done backfill, queue batch ops (select-all, selectable batch tag), review badge, review header per-question counts; tests 899/899"）

## 2. 删除记录（3/3 全部完成并逐个核对）

| # | 文件 | 删除前 blob SHA | 删除提交 | 提交时间（UTC） | 核对结果 |
|---|------|----------------|----------|----------------|----------|
| 1 | `test/b3_overlay_layer2_test.dart` | `e3a5ddb588324b4a87b029209c925cc92ab265d9` | `db5c691710dc8a65c98dd3b442e1a9c203039380` | 2026-11-15T14:24:11Z | `get_file_contents`（ref `refs/heads/ui-replication`）返回失败"file does not exist"；克隆整树中亦无此路径 ✅ |
| 2 | `test/b3_p11_layer2_downgrade_test.dart` | `658af70eec1f80a73346a8c5d7cd1083be5c7050` | `3262a0413a8929f1e6e75b5e056f54dba466bc80` | 2026-11-15T14:24:26Z | 同上 ✅ |
| 3 | `test/b5_p1_256_test.dart` | `633372502f5f2cae9f1a937b677fd1c7a6598f6e` | `a1021d7b09514d239fce262f6d08e40156523cc9` | 2026-11-15T14:24:42Z | 同上 ✅ |

提交信息分别为：

- `Batch 10: remove stale layer-2 test deleted in B8-2 (1/3)`
- `Batch 10: remove stale layer-2 test deleted in B8-2 (2/3)`
- `Batch 10: remove stale layer-2 test deleted in B8-2 (3/3)`

三次删除均为线性父子关系：`6316a23` → `db5c691` → `3262a04` → `a1021d7`。

**删除后远端新 head：`a1021d7b09514d239fce262f6d08e40156523cc9`**（经 `list_commits` 核对，head 提交信息即第 3 条删除）。

删除前三文件的远端存在性已用 `get_file_contents` 逐个核实，返回的 blob SHA 与任务给出的 SHA 逐字符一致后才动手删除。审批卡三张全部即时获批，无卡住、无重试。

## 3. 远端整树与本地整树对账

### 3.1 方法

- 远端清单：`git clone --depth 1 -b ui-replication https://github.com/MengYC1116/quiz-master2-F.git /tmp/qm2-remote-b10-1`（公开仓库，无鉴权），克隆后 head 即 `a1021d7b09514d239fce262f6d08e40156523cc9`，`git ls-files | sort` 得 644 个文件。
- 本地清单：工作树 `~/workspace/quiz-master2-UI`（分支 `ui-replication`，本地 HEAD `bca85869868e4acfa26c99ad33e0361810f7ce66`），`git ls-files --cached --others --exclude-standard | sort` 得 999 个文件（含已追踪 + 未追踪、排除 .gitignore 忽略项）。
- 比对：`comm` 逐项比对两个已排序清单。
- 排除（约定不推）：`docs/ui-replication/shots/**`、`test/fixtures/**`、`*.onnx`、`.muse-github-snapshot-sync.json*`。
- 注意：本地 HEAD 与远端 head 不在同一提交谱系上（`git merge-base --is-ancestor 6316a23 HEAD` 为否，快照推送改写了谱系），故按**路径集合**比对，而非提交图比对；路径比对不受谱系影响。

### 3.2 结论

- **只在远端有、本地没有的文件（原始）：0 个。**
  - 排除约定不推项后仍为 **0 个**——除上述 3 个已删文件外，**远端再无其他孤儿文件**，无需再删。
- **只在本地有、远端没有的文件（原始）：355 个，全部落在约定不推的排除项内，排除后为 0 个。**
  - `docs/ui-replication/shots/**`：348 个（截图，约定不推）
  - `test/fixtures/**`：7 个（测试夹具，约定不推）
  - 其中已追踪文件 0 个——355 个全部是本地未追踪文件，无任何已入库的本地文件缺失于远端。
- **对账结论：排除约定不推项后，远端与本地路径集合完全一致，无其他孤儿、无本地缺远端的文件。** 3 个已删文件在克隆的远端整树中已确认不存在。

### 3.3 本地有、远端缺的文件完整清单（355 个，均为约定不推项）

`test/fixtures/**`（7 个）：

```
test/fixtures/exif-orientation-1.jpg
test/fixtures/exif-orientation-3.jpg
test/fixtures/exif-orientation-6.jpg
test/fixtures/exif-orientation-8.jpg
test/fixtures/pdf-encrypted.pdf
test/fixtures/photo.jpg
test/fixtures/slice-narrow-500x120.png
```

`docs/ui-replication/shots/**`（348 个，完整清单见下）：

```
docs/ui-replication/shots/b2-wrongbook-cover/after-combo-dark.png
docs/ui-replication/shots/b2-wrongbook-cover/after-dark.png
docs/ui-replication/shots/b2-wrongbook-cover/after-hover-dark.png
docs/ui-replication/shots/b2-wrongbook-cover/after-light.png
docs/ui-replication/shots/b2-wrongbook-cover/before-combo-dark-empty-library.png
docs/ui-replication/shots/b2-wrongbook-cover/before-combo-dark.png
docs/ui-replication/shots/b2-wrongbook-cover/before-dark-empty-library.png
docs/ui-replication/shots/b2-wrongbook-cover/before-dark.png
docs/ui-replication/shots/b2-wrongbook-cover/before-hover-dark-empty-library.png
docs/ui-replication/shots/b2-wrongbook-cover/before-hover-dark.png
docs/ui-replication/shots/b2-wrongbook-cover/before-light-empty-library.png
docs/ui-replication/shots/b2-wrongbook-cover/before-light.png
docs/ui-replication/shots/b2-wrongbook-cover/compare-dark.png
docs/ui-replication/shots/b2-wrongbook-cover/compare-light.png
docs/ui-replication/shots/b2-wrongbook-cover/fold-compare.png
docs/ui-replication/shots/b2-wrongbook-spine/after-light.png
docs/ui-replication/shots/b8-detail/00-before.png
docs/ui-replication/shots/b8-detail/01-variant-a-compact.png
docs/ui-replication/shots/b8-detail/02-variant-b-colorband.png
docs/ui-replication/shots/b8-detail/03-variant-c-twocolumn.png
docs/ui-replication/shots/b8-list/after-A-compact.png
docs/ui-replication/shots/b8-list/after-A-empty.png
docs/ui-replication/shots/b8-list/after-A-list.png
docs/ui-replication/shots/b8-list/after-B-compact.png
docs/ui-replication/shots/b8-list/after-B-empty.png
docs/ui-replication/shots/b8-list/after-B-list.png
docs/ui-replication/shots/b8-list/after-C-compact.png
docs/ui-replication/shots/b8-list/after-C-empty.png
docs/ui-replication/shots/b8-list/after-C-list.png
docs/ui-replication/shots/b8-list/before-compact.png
docs/ui-replication/shots/b8-list/before-empty-folder.png
docs/ui-replication/shots/b8-list/before-list.png
docs/ui-replication/shots/b8-list/compare-list.png
docs/ui-replication/shots/b8-list/make-v2-shot-db.py
docs/ui-replication/shots/b8-shelf/run-shots-b8-shelf.sh
docs/ui-replication/shots/b8-shelf/shelf-1000-single.png
docs/ui-replication/shots/b8-shelf/shelf-1000.png
docs/ui-replication/shots/b8-shelf/shelf-1600.png
docs/ui-replication/shots/b9-queue-batch/after-1280.png
docs/ui-replication/shots/b9-queue-batch/after-narrow.png
docs/ui-replication/shots/b9-queue-batch/after-tag-menu.png
docs/ui-replication/shots/b9-queue-batch/before-1280.png
docs/ui-replication/shots/b9-queue-batch/before-folder-menu.png
docs/ui-replication/shots/b9-queue-batch/before-narrow.png
docs/ui-replication/shots/b9-review-badge/00-before-expanded.png
docs/ui-replication/shots/b9-review-badge/01-before-collapsed.png
docs/ui-replication/shots/b9-review-badge/02-after-expanded.png
docs/ui-replication/shots/b9-review-badge/03-after-collapsed.png
docs/ui-replication/shots/b9-review-badge/prep-before-tree.sh
docs/ui-replication/shots/b9-review-badge/run-shots-b9-3.sh
docs/ui-replication/shots/b9-review-header/00-before.png
docs/ui-replication/shots/b9-review-header/01-after.png
docs/ui-replication/shots/b9-review-header/run-shots-b9-4.sh
docs/ui-replication/shots/bugfix-20261113/cover-order-fixed.png
docs/ui-replication/shots/bugfix-20261113/nav-hover-fixed.png
docs/ui-replication/shots/p0b1-archived/01-reminder-baseline.png
docs/ui-replication/shots/p0b1-archived/02-home-baseline.png
docs/ui-replication/shots/p0b1-archived/03-detail-before-join.png
docs/ui-replication/shots/p0b1-archived/04-detail-scrolled.png
docs/ui-replication/shots/p0b1-archived/05-detail-review-section.png
docs/ui-replication/shots/p0b1-archived/06-detail-joined.png
docs/ui-replication/shots/p0b1-archived/07-home-joined.png
docs/ui-replication/shots/p0b1-archived/07b-back-to-list.png
docs/ui-replication/shots/p0b1-archived/08-review-joined.png
docs/ui-replication/shots/p0b1-archived/09-reminder-joined.png
docs/ui-replication/shots/p0b1-archived/11-detail-archived.png
docs/ui-replication/shots/p0b1-archived/12-home-archived.png
docs/ui-replication/shots/p0b1-archived/13-review-archived.png
docs/ui-replication/shots/p0b1-archived/14-reminder-archived.png
docs/ui-replication/shots/p0b1-archived/15-archived-list.png
docs/ui-replication/shots/p0b1-archived/16-home-restored.png
docs/ui-replication/shots/p0b1-archived/subject/01-shelf-chem.png
docs/ui-replication/shots/p0b1-archived/subject/02-chem-directory.png
docs/ui-replication/shots/p0b1-archived/subject/03-chem-list.png
docs/ui-replication/shots/p0b1-archived/subject/04-chem-compact.png
docs/ui-replication/shots/p0b1-refresh/after/01-home.png
docs/ui-replication/shots/p0b1-refresh/after/02-shelf.png
docs/ui-replication/shots/p0b1-refresh/after/03-directory.png
docs/ui-replication/shots/p0b1-refresh/after/04-list-large.png
docs/ui-replication/shots/p0b1-refresh/after/05-compact-before.png
docs/ui-replication/shots/p0b1-refresh/after/06-detail.png
docs/ui-replication/shots/p0b1-refresh/after/07-detail-favorited.png
docs/ui-replication/shots/p0b1-refresh/after/08-back-list.png
docs/ui-replication/shots/p0b1-refresh/after/09-compact-after-fav.png
docs/ui-replication/shots/p0b1-refresh/after/10-delete-confirm.png
docs/ui-replication/shots/p0b1-refresh/after/11-detail-after-delete.png
docs/ui-replication/shots/p0b1-refresh/after/12-list-after-delete.png
docs/ui-replication/shots/p0b1-refresh/after/13-edit-detail.png
docs/ui-replication/shots/p0b1-refresh/after/15-list-after-edit.png
docs/ui-replication/shots/p0b1-refresh/after/16-compact-after-edit.png
docs/ui-replication/shots/p0b1-refresh/after/17-detail-archived.png
docs/ui-replication/shots/p0b1-refresh/after/18-list-after-archive.png
docs/ui-replication/shots/p0b1-refresh/before/01-home.png
docs/ui-replication/shots/p0b1-refresh/before/02-shelf.png
docs/ui-replication/shots/p0b1-refresh/before/03-directory.png
docs/ui-replication/shots/p0b1-refresh/before/04-list-large.png
docs/ui-replication/shots/p0b1-refresh/before/05-compact-before.png
docs/ui-replication/shots/p0b1-refresh/before/06-detail.png
docs/ui-replication/shots/p0b1-refresh/before/07-detail-favorited.png
docs/ui-replication/shots/p0b1-refresh/before/08-back-list.png
docs/ui-replication/shots/p0b1-refresh/before/09-compact-after-fav.png
docs/ui-replication/shots/p0b1-refresh/before/10-delete-confirm.png
docs/ui-replication/shots/p0b1-refresh/before/11-detail-after-delete.png
docs/ui-replication/shots/p0b1-refresh/before/12-list-after-delete.png
docs/ui-replication/shots/p0b1-settings/after/01-home.png
docs/ui-replication/shots/p0b1-settings/after/02-review.png
docs/ui-replication/shots/p0b1-settings/after/03-review-20.png
docs/ui-replication/shots/p0b1-settings/after/04-settings.png
docs/ui-replication/shots/p0b1-settings/after/05-settings-wrongbook.png
docs/ui-replication/shots/p0b1-settings/after/06-settings-appearance.png
docs/ui-replication/shots/p0b1-settings/after/07-settings-light.png
docs/ui-replication/shots/p0b1-settings/before/01-home.png
docs/ui-replication/shots/p0b1-settings/before/02-review.png
docs/ui-replication/shots/p0b1-settings/before/03-review-20.png
docs/ui-replication/shots/p0b1-settings/before/04-settings.png
docs/ui-replication/shots/p0b1-settings/before/05-settings-wrongbook.png
docs/ui-replication/shots/p0b1-settings/before/06-settings-appearance.png
docs/ui-replication/shots/p0b1-settings/before/07-settings-light.png
docs/ui-replication/shots/p0b1-subject/01-home.png
docs/ui-replication/shots/p0b1-subject/02-organize-topbar.png
docs/ui-replication/shots/p0b1-subject/03-queue.png
docs/ui-replication/shots/p0b1-subject/04-queue-search-chem.png
docs/ui-replication/shots/p0b1-subject/05-queue-search-math.png
docs/ui-replication/shots/p0b1-subject/06-detail.png
docs/ui-replication/shots/p0b1-subject/07-detail-info.png
docs/ui-replication/shots/s8a0/nav-review-dark-hover.png
docs/ui-replication/shots/s8a0/nav-subjects-dark-hover.png
docs/ui-replication/shots/s8a1/after-detail-dark.png
docs/ui-replication/shots/s8a1/after-detail-light.png
docs/ui-replication/shots/s8a1/after-organize-dark.png
docs/ui-replication/shots/s8a1/after-organize-light.png
docs/ui-replication/shots/s8a1/after-review-dark.png
docs/ui-replication/shots/s8a1/after-zoom-drag.png
docs/ui-replication/shots/s8a1/after-zoom-wheel-91pct.png
docs/ui-replication/shots/s8a1/before-detail-light.png
docs/ui-replication/shots/s8a1/before-organize-dark.png
docs/ui-replication/shots/s8a1/before-organize-light.png
docs/ui-replication/shots/s8a1/before-review-dark.png
docs/ui-replication/shots/s8a1/recheck-detail-light.png
docs/ui-replication/shots/s8a1/recheck-organize-dark.png
docs/ui-replication/shots/s8a1/recheck-organize-light.png
docs/ui-replication/shots/s8a2-thumb/compact-dark.png
docs/ui-replication/shots/s8a2-thumb/compact-light.png
docs/ui-replication/shots/s8a2-thumb/large-cards-dark.png
docs/ui-replication/shots/s8a2/added-demo-newblue.png
docs/ui-replication/shots/s8a2/added-fresh-cover-grey.png
docs/ui-replication/shots/s8a2/added-fresh-dot-purple.png
docs/ui-replication/shots/s8a2/dot-fixed-purple.png
docs/ui-replication/shots/s8a3/01-home.png
docs/ui-replication/shots/s8a3/02-collect.png
docs/ui-replication/shots/s8a3/03-editor.png
docs/ui-replication/shots/s8a3/03b-editor.png
docs/ui-replication/shots/s8a3/04-drag-to-edge.png
docs/ui-replication/shots/s8a3/05-drag-right-edge.png
docs/ui-replication/shots/s8a3/06-drag-right-edge2.png
docs/ui-replication/shots/s8a3/07-drag-bottom-edge.png
docs/ui-replication/shots/s8a3/08-drag-bottom-right-corner.png
docs/ui-replication/shots/s8a3/09-after-cancel.png
docs/ui-replication/shots/s8a4/01-duplicate-light.png
docs/ui-replication/shots/s8a4/02-oversize-light.png
docs/ui-replication/shots/s8a4/03-duplicate-dark.png
docs/ui-replication/shots/s8a4/04-oversize-dark.png
docs/ui-replication/shots/s8a4/05-error-and-nosubject-dark.png
docs/ui-replication/shots/s8a4/06-nosubject-warning-dark.png
docs/ui-replication/shots/s8a5/00-home.png
docs/ui-replication/shots/s8a5/10-settings-all-collapsed.png
docs/ui-replication/shots/s8a5/11-settings-appearance-open.png
docs/ui-replication/shots/s8a5/13-settings-after-review-tap2.png
docs/ui-replication/shots/s8a5/30-settings-A.png
docs/ui-replication/shots/s8a5/33-settings-B.png
docs/ui-replication/shots/s8a5/34-settings-wheelup.png
docs/ui-replication/shots/s8a5/40-settings-fixed-collapsed.png
docs/ui-replication/shots/s8a5/41-settings-fixed-appearance-open.png
docs/ui-replication/shots/s8a5/42-settings-fixed-review-open.png
docs/ui-replication/shots/s8a5/43-subjects-fixed-collapsed.png
docs/ui-replication/shots/s8a5/44-subjects-fixed-knowledge-open.png
docs/ui-replication/shots/s8a5/45-home-fixed.png
docs/ui-replication/shots/s8a5/46-wrongbook-fixed.png
docs/ui-replication/shots/s8a5/47-wrongbook-math-list.png
docs/ui-replication/shots/s8a5/48-wrongbook-math-questions.png
docs/ui-replication/shots/s8a5/49-detail-before.png
docs/ui-replication/shots/s8a5/50-detail-after-answer-tap.png
docs/ui-replication/shots/s8a5/51-organize-before.png
docs/ui-replication/shots/s8a5/52-organize-after-source-tap.png
docs/ui-replication/shots/s8a6/00-home.png
docs/ui-replication/shots/s8a6/10-wrongbook-shelf.png
docs/ui-replication/shots/s8a6/11-wrongbook-math-dir.png
docs/ui-replication/shots/s8a6/20-wb-p10-p1-top.png
docs/ui-replication/shots/s8a6/21-wb-p10-p1-bottom.png
docs/ui-replication/shots/s8a6/21c-wb-p10-p1-bottom3.png
docs/ui-replication/shots/s8a6/22d-wb-click-p2.png
docs/ui-replication/shots/s8a6/25-wb-p10-p6c.png
docs/ui-replication/shots/s8a6/26-wb-p10-p6-top.png
docs/ui-replication/shots/s8a6/27-wb-dropdown-open.png
docs/ui-replication/shots/s8a6/28-wb-p20-p1-bottom.png
docs/ui-replication/shots/s8a6/29-wb-p20-p3-bottom.png
docs/ui-replication/shots/s8a6/30-wb-p30-p1-bottom.png
docs/ui-replication/shots/s8a6/31-wb-p30-p2-bottom.png
docs/ui-replication/shots/s8a6/32-wb-p40-p1-bottom.png
docs/ui-replication/shots/s8a6/33-wb-p40-p2-bottom.png
docs/ui-replication/shots/s8a6/34-wb-p50-p1-bottom.png
docs/ui-replication/shots/s8a6/35-wb-p50-p2-bottom.png
docs/ui-replication/shots/s8a6/36-wb-p50-p2-top.png
docs/ui-replication/shots/s8a6/37-wb-compact-p50-p2.png
docs/ui-replication/shots/s8a6/38-wb-compact-p10-p1.png
docs/ui-replication/shots/s8a6/38a-wb-compact-dropdown.png
docs/ui-replication/shots/s8a6/39-wb-compact-p10-p1-bottom.png
docs/ui-replication/shots/s8a6/41-wb-search52.png
docs/ui-replication/shots/s8a6/42-wb-after-reset.png
docs/ui-replication/shots/s8a6/50-review-p10-p1-top.png
docs/ui-replication/shots/s8a6/51-review-p10-p1-bottom.png
docs/ui-replication/shots/s8a6/52-review-p10-p2-bottom.png
docs/ui-replication/shots/s8a6/54-review-p10-p6.png
docs/ui-replication/shots/s8a6/55-review-dropdown.png
docs/ui-replication/shots/s8a6/56-review-p20-p1-bottom.png
docs/ui-replication/shots/s8a6/57-review-p20-p1-bottom.png
docs/ui-replication/shots/s8a6/58-review-p20-p3-bottom.png
docs/ui-replication/shots/s8a6/59-review-p30-p1.png
docs/ui-replication/shots/s8a6/60-review-p30-p1-bottom.png
docs/ui-replication/shots/s8a6/61-review-p30-p1-bottom2.png
docs/ui-replication/shots/s8a6/62-review-p30-p1-bottom3.png
docs/ui-replication/shots/s8a6/63-review-dropdown40.png
docs/ui-replication/shots/s8a6/64-review-p30-p1-bottom.png
docs/ui-replication/shots/s8a6/65-review-p30-p2-bottom.png
docs/ui-replication/shots/s8a6/66-review-p40-p1-top.png
docs/ui-replication/shots/s8a6/67-review-p40-p1-bottom.png
docs/ui-replication/shots/s8a6/68-review-p40-p2-bottom.png
docs/ui-replication/shots/s8a6/69-review-p50-p1-bottom.png
docs/ui-replication/shots/s8a6/70-review-p50-p1-bottom2.png
docs/ui-replication/shots/s8a6/71-review-p50-p1-bottom3.png
docs/ui-replication/shots/s8a6/72-review-p50-p2-bottom.png
docs/ui-replication/shots/s8a6/73-review-subject-dropdown.png
docs/ui-replication/shots/s8a6/74-review-filter-math.png
docs/ui-replication/shots/s8a6/75-review-filter-math-bottom.png
docs/ui-replication/shots/s8a6/76-review-filter-math-bottom2.png
docs/ui-replication/shots/s8a6/77-review-filter-math-bottom3.png
docs/ui-replication/shots/s8a6/78-review-filter-math-bottom4.png
docs/ui-replication/shots/s8a6/80-home-restored.png
docs/ui-replication/shots/s8b1/probe-report-dark-standard.png
docs/ui-replication/shots/s8b1/report-all-dark-standard.png
docs/ui-replication/shots/s8b1/report-month-dark-standard.png
docs/ui-replication/shots/s8b1/report-week-dark-standard.png
docs/ui-replication/shots/s8b2-supplement/collect-menu-dark.png
docs/ui-replication/shots/s8b2-supplement/collect-menu-light.png
docs/ui-replication/shots/s8b2-supplement/collect-selected-dark.png
docs/ui-replication/shots/s8b2-supplement/collect-selected-light.png
docs/ui-replication/shots/s8b2-supplement/probe-collect-dark.png
docs/ui-replication/shots/s8b2-supplement/probe-home-dark.png
docs/ui-replication/shots/s8b2-supplement/probe-report-dark.png
docs/ui-replication/shots/s8b2-supplement/probe-review-dark.png
docs/ui-replication/shots/s8b2-supplement/probe-shelf-dark.png
docs/ui-replication/shots/s8b2-supplement/report-dist-dark.png
docs/ui-replication/shots/s8b2-supplement/report-dist-light.png
docs/ui-replication/shots/s8b2-supplement/report-top-dark.png
docs/ui-replication/shots/s8b2-supplement/review-filtered-dark.png
docs/ui-replication/shots/s8b2-supplement/review-filtered-light.png
docs/ui-replication/shots/s8b2-supplement/review-menu-dark.png
docs/ui-replication/shots/s8b2-supplement/review-menu-light.png
docs/ui-replication/shots/s8b2-supplement/wrongbook-compact-dark.png
docs/ui-replication/shots/s8b2-supplement/wrongbook-compact-light.png
docs/ui-replication/shots/s8b2-supplement/wrongbook-dir-dark.png
docs/ui-replication/shots/s8b2-supplement/wrongbook-dir-light.png
docs/ui-replication/shots/s8b2-supplement/wrongbook-list-dark.png
docs/ui-replication/shots/s8b2/home-4-dark-standard.png
docs/ui-replication/shots/s8b2/home-4-light-standard.png
docs/ui-replication/shots/s8b2/home-6-dark-standard.png
docs/ui-replication/shots/s8b2/home-6-light-standard.png
docs/ui-replication/shots/s8b3/01-start-last-home.png
docs/ui-replication/shots/s8b3/02-organize-after-click.png
docs/ui-replication/shots/s8b3/03-restart-restores-organize.png
docs/ui-replication/shots/s8b3/04-start-home-again.png
docs/ui-replication/shots/s8b3/probe-home-dark.png
docs/ui-replication/shots/s8b4/01-reminder-shows.png
docs/ui-replication/shots/s8b4/03-reminder-shows-again.png
docs/ui-replication/shots/s8b4/04-reminder-go-review.png
docs/ui-replication/shots/s8b4/05-no-repeat-same-day.png
docs/ui-replication/shots/s8b4/06-disabled-no-reminder.png
docs/ui-replication/shots/s8b4/07-before-time-no-reminder.png
docs/ui-replication/shots/s8b4/08-reminder-dismiss.png
docs/ui-replication/shots/s8b4/09-settings.png
docs/ui-replication/shots/s8b4/10-settings-data.png
docs/ui-replication/shots/s8b4/11-backup-no-dialog-zenity-limitation.png
docs/ui-replication/shots/s8b4/13-backup-saved.png
docs/ui-replication/shots/s8b4/14-restore-confirm.png
docs/ui-replication/shots/s8b4/15-restored.png
docs/ui-replication/shots/s8b4/16-migrated-snack.png
docs/ui-replication/shots/s8b4/17-new-location.png
docs/ui-replication/shots/s8b4/18-target-exists-dialog.png
docs/ui-replication/shots/s8b4/19-kept-snack.png
docs/ui-replication/shots/s8b4/20-kept-location.png
docs/ui-replication/shots/s8b4/21-target-exists-dialog-default.png
docs/ui-replication/shots/s8b4/22-overwrote-snack.png
docs/ui-replication/shots/s8b4/23-back-to-default.png
docs/ui-replication/shots/s8b6b7/01-b7-legacy-collect-home.png
docs/ui-replication/shots/s8b6b7/02-b7-collect-page.png
docs/ui-replication/shots/s8b6b7/03-organize-page.png
docs/ui-replication/shots/s8b6b7/04-review-page.png
docs/ui-replication/shots/s8b6b7/05-collect-dropdown.png
docs/ui-replication/shots/s8b6b7/06-b7-collect-imported.png
docs/ui-replication/shots/s8b6b7/07-b7-home-after-collect.png
docs/ui-replication/shots/s8b6b7/08-organize-scrolled.png
docs/ui-replication/shots/s8b6b7/09-b6-archived-review.png
docs/ui-replication/shots/s8b6b7/10-b7-organize-confirmed.png
docs/ui-replication/shots/s8b6b7/11-b7-home-after-organize.png
docs/ui-replication/shots/s8b6b7/12-b6-unarchived-review.png
docs/ui-replication/shots/s8b6b7/13-leftover1-session-recall.png
docs/ui-replication/shots/s8b6b7/14-leftover1-session-remedy.png
docs/ui-replication/shots/s8b6b7/15-leftover1-session-redo.png
docs/ui-replication/shots/s8b6b7/16-leftover1-session-redo-shown.png
docs/ui-replication/shots/s8b6b7/17-leftover1-session-check.png
docs/ui-replication/shots/s8b6b7/18-leftover1-advanced-next-block.png
docs/ui-replication/shots/s8b6b7/19-leftover1-after-recheck.png
docs/ui-replication/shots/s8b6b7/20-leftover3-settings.png
docs/ui-replication/shots/s8b6b7/21-leftover3-settings-data.png
docs/ui-replication/shots/s8b6b7/22-leftover3-backup-failed-snack.png
docs/ui-replication/shots/s8b6b7/23-leftover3-home-banner.png
docs/ui-replication/shots/s8b6b7/24-leftover3-home-dismissed.png
docs/ui-replication/shots/s8b6b7/25-leftover3-home-after-restart.png
docs/ui-replication/shots/s8chip/collect-task-dark.png
docs/ui-replication/shots/s8chip/collect-task-light.png
docs/ui-replication/shots/s8chip/probe-collect-dark.png
docs/ui-replication/shots/s8chip/probe-home-dark.png
docs/ui-replication/shots/s8chip/probe-report-dark.png
docs/ui-replication/shots/s8chip/probe-review-dark.png
docs/ui-replication/shots/s8chip/probe-shelf-dark.png
docs/ui-replication/shots/s8chip/report-next-dark.png
docs/ui-replication/shots/s8chip/report-next-light.png
docs/ui-replication/shots/s8chip/review-filtered-dark.png
docs/ui-replication/shots/s8chip/review-filtered-light.png
docs/ui-replication/shots/s8chip/review-menu-dark.png
docs/ui-replication/shots/s8chip/review-menu-light.png
docs/ui-replication/shots/s8chip/subjects-kp-chem-dark.png
docs/ui-replication/shots/s8chip/subjects-kp-chem-light.png
docs/ui-replication/shots/s8chip/subjects-kp-dark.png
docs/ui-replication/shots/s8chip/subjects-kp-light.png
docs/ui-replication/shots/s8chip/subjects-top-dark.png
docs/ui-replication/shots/s8chip/subjects-top-light.png
docs/ui-replication/shots/s8chip/wrongbook-dir-dark.png
docs/ui-replication/shots/s8chip/wrongbook-dir-light.png
docs/ui-replication/shots/yolo/annotated-l1-16676QPFVu1ck984AfWQHruoHWRfTz99b.png
docs/ui-replication/shots/yolo/annotated-l1-1TYQmeLkJc40U4X5s6v5xou3MmrDtzrEf.png
docs/ui-replication/shots/yolo/annotated-l1-1iMDN14nE6qZD_srN4VHi1yCZ5j6ywg_D.png
docs/ui-replication/shots/yolo/e2e-01-home.png
docs/ui-replication/shots/yolo/e2e-02-collect.png
docs/ui-replication/shots/yolo/e2e-03-task-needbox.png
docs/ui-replication/shots/yolo/e2e-04-editor-13-boxes.png
docs/ui-replication/shots/yolo/e2e-05-editor-inner-mode.png
docs/ui-replication/shots/yolo/e2e-06-after-cancel.png
```

## 4. 验证

- 本项未改本地任何代码（本地工作树事先已有的未提交 Batch 10 改动原样未动，也未 commit）。
- `flutter analyze`（`~/workspace/flutter-install/flutter/bin/flutter analyze`）：**No issues found!**（16.4s）。
- 未跑测试（任务不要求），未碰数据库，未跑应用。

## 5. 后续

- 无。本项闭环：3 个孤儿已删、逐个核对通过、整树对账干净。
- 下次快照推送时远端将自然与本地一致（本次只删文件，未推任何本地内容）。
