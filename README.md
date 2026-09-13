# 言落 VoxDrop：macOS 本地语音输入

言落（VoxDrop）是一个面向 Apple Silicon Mac 的本地语音输入工具。按下全局快捷键说话，松开后，识别结果会自动粘贴到当前光标。ASR 全程在本机运行，不需要云端 API，也不会上传录音。

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

## 安装发行版

发行版支持 **Apple Silicon（M 系列）、macOS 26.2+**。下载 `VoxDrop-0.1.0-macos-arm64.dmg` 后，把“言落”拖入“应用程序”即可；Python 3.11、MLX 和 Qwen3-ASR 模型已经内置，用户不需要安装 Python、uv、Homebrew、ffmpeg、Xcode，也不需要在首次启动时下载模型。

当前版本没有 Apple Developer ID 和公证。第一次打开若被 macOS 拦截，请先尝试打开一次，再进入“系统设置 → 隐私与安全性”确认打开；随后按引导授予麦克风、输入监控和辅助功能权限。

当前候选 DMG 为 710,724,230 字节，SHA-256 见随发行包提供的 `SHA256SUMS.txt`。完整安装说明见 [GitHub Release 说明](docs/GitHub-Release说明.md)。

## 克隆后快速使用

### 1. 准备环境

以下是源码开发流程，不是发行版用户的前置依赖。开发环境支持 **Apple Silicon（arm64）、macOS 26.2+**。先安装 Xcode Command Line Tools、[Homebrew](https://brew.sh/)、uv 和 ffmpeg：

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

脚本会构建并启动 `build/言落.app`。启动后，Finder、Spotlight、Dock 与屏幕顶部菜单栏都会显示“言落”；首次启动会自动打开使用引导。

### 5. 授予 macOS 权限

首次启动需要三项权限：

1. **麦克风**：录制语音。
2. **输入监控**：监听全局快捷键。
3. **辅助功能**：向当前光标发送 Command+V。

进入“系统设置 → 隐私与安全性”，在上述三个页面中打开“言落”。如果“输入监控”或“辅助功能”没有自动出现“言落”，点击加号，手动选择仓库中的：

~~~text
build/言落.app
~~~

授权后，从菜单栏完全退出“言落”，再执行一次：

~~~bash
./scripts/run-macos-app.sh
~~~

可在“言落 → 设置 → 诊断”中确认三项权限均为“已授权”。

### 6. 开始使用

先将光标放入任意文本输入框：

- **Hold**：按住 Option+A 说话，松开后识别并粘贴。
- **Toggle**：按 Option+S 开始，再按一次结束。
- **取消**：录音或识别期间按 Esc。

快捷键可在“设置 → 通用”中修改。热词可在“设置 → 热词”中按行添加、编辑、停用或删除。

## 常见问题

| 现象 | 处理方法 |
|---|---|
| 菜单显示“不可用” | 打开“设置 → 诊断”，核对模型路径和三项权限，然后点击“重新加载 Worker”。 |
| 全局快捷键没有反应 | 检查“输入监控”和“辅助功能”，完全退出并重启 App。 |
| 结果进入剪贴板但未自动粘贴 | 确认光标仍在输入框，并检查“辅助功能”；不要让剪贴板管理器面板停留在前台。 |
| 开发版提示模型目录不存在 | 重新执行上面的模型下载命令，并保持模型目录名称不变。 |
| 移动仓库后开发版启动失败 | 重新执行 scripts/run-macos-app.sh，它会更新开发 App 使用的项目路径。发行版不依赖仓库。 |

## 开发说明

- macOS 界面：Swift / SwiftUI，位于 apps/macos/。
- ASR Worker：Python 3.11 / MLX Audio，位于 voice_input/。
- `scripts/run-macos-app.sh` 构建面向源码仓库的开发版；`scripts/build-macos-release.sh` 构建使用包内 runtime/model 的离线发行版。
- 已生成经过 ad-hoc 签名的自包含 DMG；由于没有 Developer ID，当前版本不做 Apple 公证，首次打开会有系统警告。
- 完整环境、评测和打包资料见 docs/ 与 [环境搭建指引](环境搭建指引.md)。
