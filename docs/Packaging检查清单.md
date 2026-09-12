# 后续 Packaging 检查清单

- [ ] 确定正式产品名、图标、Bundle ID 和最低 macOS 版本。
- [x] 开发 runtime/model 的 ID、相对路径和校验摘要已记录在 `config/runtime-resources.json`。
- [ ] 决定模型随包、外置安装或下载；记录 SHA-256、来源和许可证。
- [ ] 构建可重定位的 Python 3.11 runtime，不复制开发 `.venv` 冒充分发环境。
- [ ] 收集并签名 MLX 动态库、Metal 资源及 Python 扩展；验证 hardened runtime。
- [x] 从 `/private/tmp` 调用脚本并解析中文项目路径完成构建；App 内真实录音仍待权限后验收。
- [ ] 在无 uv、无 Homebrew、无项目源码的干净 Apple Silicon Mac 验证。
- [ ] Developer ID 签名、notarytool 公证、staple 与 Gatekeeper 验证。
- [ ] 核对 Python、mlx-audio、模型和所有随包依赖的第三方许可。
- [ ] 确认用户数据、日志和临时音频均写在 bundle 外。
- [ ] DMG 仅在以上条件验证后制作；本 MVP 不生成正式 DMG。
