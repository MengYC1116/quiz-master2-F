# ONNX 模型占位说明

真模型：`best.onnx`（约 37 MB，2026-11-03），`best.pt`（约 19 MB）。
用户提供后，把 `best.onnx` 放到本目录（`assets/models/best.onnx`），
并删除本说明文件；`.gitignore` 已把真模型排除在 git 之外（37 MB 可直接
进 GitHub，单文件上限 100 MB，无需 LFS）。

在真模型到位前，`lib/services/yolo_onnx_service.dart` 以占位模式运行：
对一页返回一个覆盖页面的整题框，收集 → 整理链路可先跑通。
