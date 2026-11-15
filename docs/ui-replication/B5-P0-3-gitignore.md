# B5-P0-3：YOLO 模型文件 .gitignore 保护（SR-P0-3）

- 日期：2026-11-14
- 分支：`ui-replication`（工作树 `~/workspace/quiz-master2-UI`）
- 问题来源：`docs/ui-replication/SELF-REVIEW.md` SR-P0-3；`SELF-REVIEW-SUMMARY.md` P0 第 3 项；Batch 3 待定第 1 项（Meng 已批准：12 项决定第 1 条）

## 结果

已修复。38MB YOLO 模型文件现被 `.gitignore` 忽略，一次习惯性的 `git add .` 不会再把它写进历史；`assets/models/README.md` 仍在库内；模型文件本身未动；`pubspec.yaml` 未动。

## 改动

仅改 1 个文件：`.gitignore`，末尾新增 3 行（注释 2 行 + 规则 1 行）：

```gitignore
# YOLO 模型文件（约 38MB）不进仓库，由 Meng 自己放到 assets/models/ 下
# （SR-P0-3：一次 git add . 就会把模型写进历史）
assets/models/**/*.onnx
```

修法说明：

- 按已定修法，未再问。选用 `assets/models/**/*.onnx`（而非仅 `assets/models/question/*.onnx`）：gitignore 里 `a/**/b` 可匹配零层及以上目录，因此一条规则同时覆盖 `assets/models/question/*.onnx`（当前模型）和 `assets/models/*.onnx`（README 提到的旧 `best.onnx` 位置）及未来新增子目录下的模型。
- 规则只匹配 `.onnx`，`assets/models/README.md` 不受影响，仍可入库。
- 未动模型文件本身，未动 `pubspec.yaml` 的模型打包声明（`assets/models/` / `assets/models/question/` 仍正常打进包）。

## 验证（命令与输出）

修前复核（与自审一致）：

```
$ git check-ignore -v assets/models/question/yolo11s-question-v1.onnx
（无输出，exit=1）→ NOT IGNORED
$ grep -i "models\|onnx" .gitignore
（无匹配）
$ git ls-files assets/
assets/models/README.md
```

修后验证：

```
$ git check-ignore -v assets/models/question/yolo11s-question-v1.onnx
.gitignore:52:assets/models/**/*.onnx	assets/models/question/yolo11s-question-v1.onnx
（exit=0 → 已忽略）

$ git check-ignore -v assets/models/best.onnx
.gitignore:52:assets/models/**/*.onnx	assets/models/best.onnx
（exit=0 → 顶层模型同样被忽略）

$ git ls-files assets/
assets/models/README.md
（库内仍只有 README）

$ git status --short assets/
（空：assets/ 下无未入库/已改动项，之前 `?? assets/models/question/` 已消失）

$ git add --dry-run --all | grep -i "\.onnx"
（无输出 → 无 .onnx 文件会被加入；仅做 dry-run，未实际 add）

$ ls -la assets/models/question/ && md5sum assets/models/question/yolo11s-question-v1.onnx
-rw-rw---- 38432570 yolo11s-question-v1.onnx
fb053a54093b7c3d0f1c208510640590  assets/models/question/yolo11s-question-v1.onnx
（模型文件未动：大小与修前一致，38,432,570 字节）

$ git diff .gitignore
仅末尾新增上述 3 行，其余无改动。

$ git status --short .gitignore
 M .gitignore
```

## 未做的事

- 未跑构建：`.gitignore` 只影响 git，不影响 Flutter 构建；任务亦明确不需要跑构建。
- 未跑 `flutter analyze` 与全量测试：改动不涉及任何 Dart 代码。
- 未碰真实演示库，未 commit、未 push，未动 git 历史，未用 `git reset --hard` / `git checkout --` / `git clean`。

## 结论

SR-P0-3 已关闭。模型文件已有 `.gitignore` 保护，`git add .` 安全；README 仍在库内；模型文件与打包声明均未动。
