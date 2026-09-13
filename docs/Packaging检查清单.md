# 后续 Packaging 检查清单

- [x] 正式产品名为“言落（VoxDrop）”，图标源文件为根目录 `图标.png`，Bundle ID 为 `com.local.VoxDrop`，最低版本为 macOS 26.2。
- [x] 开发 runtime/model 的 ID、相对路径和校验摘要已记录在 `config/runtime-resources.json`。
- [x] 模型随 App 分发，不启动后下载；SHA-256、来源和许可证已写入发行清单。
- [x] 已构建可重定位的 Python 3.11 runtime，不复制带绝对链接的开发 `.venv`。
- [x] 已收集并逐层 ad-hoc 签名 MLX 动态库、Metal 资源及 Python 扩展；当前无 Developer ID，不能使用可信分发签名/公证。
- [x] 从 `/private/tmp` 调用脚本并解析中文项目路径完成构建；App 内真实录音仍待权限后验收。
- [ ] 在无 uv、无 Homebrew、无项目源码的另一台 Apple Silicon Mac 验证。
- [ ] 实测未公证版本的 Gatekeeper“仍要打开”流程；Developer ID、公证和 staple 不属于当前无证书版本。
- [x] Python、mlx-audio、模型和随包 Python 依赖的许可证/元数据已收集到 App 的 `Resources/licenses`。
- [x] 用户数据和临时音频均写在 bundle 外；Worker 使用 `-I -B`，不会生成包内缓存。
- [x] 已生成并挂载验证 710,724,230 字节的 DMG，严格小于 1,000,000,000 字节。
