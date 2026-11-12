# Windows 平台脚手架

本目录为 Flutter 3.47.9 的 Windows 平台模板文件（`flutter create` 生成，
按 quiz-master2 改了应用名与窗口标题）。

在 Win11 上如果构建报错，先尝试重新生成平台目录（不会覆盖 `lib/`）：

```bat
flutter create --platforms=windows .
```

再执行：

```bat
flutter pub get
flutter run -d windows
flutter build windows --release
```

窗口默认 1280×800（预览口径），标题 `quiz-master2`。
