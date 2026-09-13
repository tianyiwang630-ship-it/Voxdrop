# 独立 M 系列 Mac 发行验收步骤

本步骤必须在不是构建机的 Apple Silicon Mac 上执行。目标系统为 macOS 26.2 或更高版本；测试机不需要安装 Python、uv、Homebrew、ffmpeg、Xcode 或项目源码。

## 准备

1. 只把 `VoxDrop-0.1.0-macos-arm64.dmg` 和 `SHA256SUMS.txt` 传到测试机。
2. 核对 DMG SHA-256 与发布文件一致。
3. 清除旧版“言落”和旧权限记录，退出同 Bundle ID 的进程。
4. 断开网络或使用确定无外网的测试网络；确认本机没有该模型的 Hugging Face 缓存。

## 必过流程

1. 打开 DMG，把“言落”拖入“应用程序”，随后推出 DMG。
2. 从“应用程序”第一次打开。记录 macOS 的拦截文案，再到“系统设置 → 隐私与安全性”完成“仍要打开”。
3. 分别验证麦克风、输入监控、辅助功能的拒绝、允许和授权后重启恢复；App 不能永久停在“启动中”。
4. 在浏览器普通文本框中测试 `Option+A` Hold、`Option+S` Toggle 和 `Esc` 取消；中文、英文、中英混输各至少一条。
5. 确认断网首次识别成功，活动监视器中没有外部 Python/ffmpeg/Homebrew 进程，也没有模型下载提示。
6. 在无障碍权限关闭时确认正文仍能进入剪贴板但不会错误粘贴；重新授权后恢复自动粘贴。
7. 测试休眠唤醒、麦克风拔插、连续 30 次短句、一次 120 秒上限和退出重开。
8. 覆盖安装同版本，确认历史、热词和快捷键设置仍保留。

## 记录要求

记录 Mac 型号/芯片、内存、macOS 完整版本、DMG SHA-256、每项结果、失败截图和 Console 中的 VoxDrop 错误。只有全部必过项通过后，才把 `dist/release-validation.json` 中对应 `manual_external_checks` 从 `not_tested` 更新为 `passed`，并运行发布脚本。
