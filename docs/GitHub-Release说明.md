# 言落 VoxDrop 0.1.0（macOS Apple Silicon）

言落是一款完全本地运行的 macOS 语音输入工具。本版本已经把 Qwen3-ASR 4-bit 模型、Python 3.11 和 MLX 运行环境全部放入 App，安装和首次识别都不需要下载模型，也不要求安装 Python、uv、Homebrew、ffmpeg 或 Xcode。

## 系统要求

- Apple Silicon（M 系列）Mac
- macOS 26.2 或更高版本
- 首次使用需要授予麦克风、辅助功能和输入监控权限

## 安装

1. 下载 DMG 并核对随附的 SHA-256。
2. 打开 DMG，把“言落”拖入“应用程序”。
3. 第一次打开时，由于当前版本没有 Apple Developer ID 和公证，macOS 会显示安全警告。先尝试打开一次，再进入“系统设置 → 隐私与安全性”，确认打开该 App。
4. 按应用内引导授予麦克风、辅助功能和输入监控权限；授权后退出并重新打开 App。

## 默认快捷键

- `Option+A`：按住说话，松开识别
- `Option+S`：按一次开始，再按一次结束
- `Esc`：取消当前录音或识别

## 隐私与已知限制

- 识别在本机完成，不上传录音或转写正文。
- 历史保存在当前用户的 Application Support 目录，临时 WAV 会在会话结束后删除。
- 未签署 Developer ID、未公证是本版本唯一预期的安装警告，不代表包内缺少运行依赖。
- 当前发行版仅支持 macOS 26.2+ 的 M 系列 Mac，不支持 Intel Mac。
