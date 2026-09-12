# VoiceInput：macOS 本地语音输入

VoiceInput 是一个面向 Apple Silicon Mac 的本地语音输入工具。按下全局快捷键说话，松开后，识别结果会自动粘贴到当前光标。ASR 全程在本机运行，不需要云端 API，也不会上传录音。

## 为什么做这个项目

目标是让语音输入真正替代键盘输入：不需要切换应用，不需要手动复制结果，在浏览器、微信、ChatGPT 等应用中都能直接对着当前光标说话。

## 模型评测与选择

项目使用 10 条自建语音进行统一评测，覆盖中文日常对话、英文日常对话、中英混输、专业热词和长句五个场景。相同脚本对比了 Qwen3-ASR、faster-whisper、SeACo-Paraformer、Sherpa Zipformer 和 Nemotron，主要观察：

- 中文 CER、英文 WER 和中英混合 MER；
- 推理延迟、RTF、加载时间、内存和模型体积；
- 开启热词前后的召回率与整体准确率。

当前数据上，**Qwen3-ASR 0.6B MLX 4bit** 的基础 MER 为 **2.64%**，中英混输和长句 MER 为 **0%**；开启热词后整体 MER 降至 **2.26%**。因此 macOS MVP 选择了 **mlx-community/Qwen3-ASR-0.6B-4bit**。

评测语音和参考文本位于 data/dataSet forASR/，评测脚本位于 benchmark/，完整结果见 [ASR Benchmark 报告](results/ASR_Benchmark报告.md)。以后更换模型时可以继续复用这套数据和评测流程。

## 产品功能

- Hold 和 Toggle 两种全局语音输入模式。
- 识别完成后向当前光标发送系统级 Command+V。
- 本地 Qwen3-ASR/MLX 推理，支持中文、英文和中英混输。
- 热词添加、编辑、启停和删除，改善人名、项目名及专业词识别。
- 本地转写历史、搜索、复制和删除。
- 会话完成或取消后删除临时录音，不上传遥测。

## 克隆后快速使用

### 1. 准备环境

目前支持 **Apple Silicon（arm64）、macOS 13+**。先安装 Xcode Command Line Tools、[Homebrew](https://brew.sh/)、uv 和 ffmpeg：

~~~bash
xcode-select --install
brew install uv ffmpeg
~~~

克隆仓库并进入项目目录：

~~~bash
git clone <repository-url>
cd <repository-directory>
~~~

### 2. 安装 Python 和 MLX 环境

~~~bash
source scripts/project-env.sh
uv python install 3.11 --install-dir "$UV_PYTHON_INSTALL_DIR" --no-bin
uv sync --project . --python 3.11 --frozen
uv sync --project envs/mlx --python 3.11 --frozen
~~~

### 3. 下载 Qwen3-ASR 模型

模型约 680 MB，是公开模型，无需 API Key。下面固定到本项目已经验证的版本：

~~~bash
mkdir -p models/qwen3-asr
uv run --project . --frozen python -c 'from huggingface_hub import snapshot_download; snapshot_download(repo_id="mlx-community/Qwen3-ASR-0.6B-4bit", revision="313d850181767edf09f00a9c289becca70e58cd0", local_dir="models/qwen3-asr/Qwen3-ASR-0.6B-4bit")'
~~~

### 4. 构建并启动 App

~~~bash
./scripts/run-macos-app.sh
~~~

脚本会构建并启动 build/VoiceInput.app。VoiceInput 是菜单栏应用，不会显示普通主窗口；启动后，屏幕顶部菜单栏会出现麦克风图标，状态应为 **Ready**。

### 5. 授予 macOS 权限

首次启动需要三项权限：

1. **麦克风**：录制语音。
2. **输入监控**：监听全局快捷键。
3. **辅助功能**：向当前光标发送 Command+V。

进入“系统设置 → 隐私与安全性”，在上述三个页面中打开 VoiceInput。如果“输入监控”或“辅助功能”没有自动出现 VoiceInput，点击加号，手动选择仓库中的：

~~~text
build/VoiceInput.app
~~~

授权后，从菜单栏完全退出 VoiceInput，再执行一次：

~~~bash
./scripts/run-macos-app.sh
~~~

可在“VoiceInput → 设置 → 诊断”中确认三项权限均为“已授权”。

### 6. 开始使用

先将光标放入任意文本输入框：

- **Hold**：按住 Control+Option+Space 说话，松开后识别并粘贴。
- **Toggle**：按 Control+Option+Command+Space 开始，再按一次结束。
- **取消**：录音或识别期间按 Esc。

快捷键可在“设置 → 通用”中修改。热词可在“设置 → 热词”中按行添加、编辑、停用或删除。

## 常见问题

| 现象 | 处理方法 |
|---|---|
| 菜单显示“不可用” | 打开“设置 → 诊断”，核对模型路径和三项权限，然后点击“重新加载 Worker”。 |
| 全局快捷键没有反应 | 检查“输入监控”和“辅助功能”，完全退出并重启 App。 |
| 结果进入剪贴板但未自动粘贴 | 确认光标仍在输入框，并检查“辅助功能”；不要让剪贴板管理器面板停留在前台。 |
| 提示模型目录不存在 | 重新执行上面的模型下载命令，并保持模型目录名称不变。 |
| 移动仓库后启动失败 | 重新执行 scripts/run-macos-app.sh，它会更新 App 使用的项目路径。 |

## 开发说明

- macOS 界面：Swift / SwiftUI，位于 apps/macos/。
- ASR Worker：Python 3.11 / MLX Audio，位于 voice_input/。
- 当前是面向源码仓库的本地开发版，App 会使用仓库内的 Python 环境和模型。
- 目前尚未制作包含独立 runtime 和模型、经过 Developer ID 签名及公证的正式 DMG。
- 完整环境、评测和打包资料见 docs/ 与 [环境搭建指引](环境搭建指引.md)。
