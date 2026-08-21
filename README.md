# DeepSeek Harness for fnOS (飞牛私有云 NAS)

[![Build and Release DeepSeek Harness FPK](https://github.com/10000ge10000/deepseek-harness-fpk/actions/workflows/build-and-release.yml/badge.svg)](https://github.com/10000ge10000/deepseek-harness-fpk/actions/workflows/build-and-release.yml)

本项目为 **DeepSeek Harness** 在 **飞牛私有云 NAS (fnOS)** 上的专属定制离线安装包（`.fpk`）及自动构建流水线。

---

## 🌟 定制特性

1. **一键开箱即用（一万AI分享专属定制）**：
   - 内置公益站点 API 端点：`https://api.910501.xyz/v1`
   - 预制模型提供商在设置中显示为 **一万AI分享**；内部兼容 DeepSeek 官方路由，不会把用户已有配置改名或锁定。
   - 模型、Base URL 和 API Key 均可编辑；可使用多个模型，也可新增自己的提供商。
   - 安装向导仅需输入 API Key（可跳过），完全无需复杂参数配置。
2. **极简 2 步安装向导**：
   - 包含一键直达公益站及 B 站视频教程超链接。
   - 移除多余的端口交互（内置安全固定端口）。
3. **工作区与飞牛桌面【文件管理】100% 同步互通**：
   - 应用数据目录直接与飞牛桌面【文件管理】$\rightarrow$【应用文件】$\rightarrow$【`DeepSeekHarness`】桥接。
   - 在应用内创建的工程、项目代码、文件实时可见，支持在线管理与下载。
4. **局域网环境无缝支持**：
   - 内置安全上下文 Polyfill 与反向代理支持，完美适配 HTTP / 局域网非安全上下文环境。

---

## 📥 安装方法

1. 前往本项目的 [Releases 页面](https://github.com/10000ge10000/deepseek-harness-fpk/releases) 下载适合您 NAS 硬件架构的 `.fpk` 安装包：
   - **x86_64 设备**（Intel / AMD CPU）：下载 `*_x86.fpk`
   - **ARM 设备**（Rockchip / Allwinner / 树莓派 / ARM64 CPU）：下载 `*_arm.fpk`
2. 登录飞牛 NAS 桌面，打开 **【应用中心】**。
3. 点击右上角 **【手动安装】**，选择下载的 `.fpk` 文件。
4. 按照向导提示填入您的 API 密钥（若无密钥可直接点击下一步），完成安装。
5. 在飞牛桌面点击 **DeepSeek Harness** 图标即可启动使用！

---

## 🛠 开发与测试

- **测试套件**（零依赖，本地与 CI 通用）：`bash tests/run-tests.sh`
- **构建安装包**（需 Linux/macOS，会下载 Node 运行时并执行 npm install）：
  ```bash
  VERSION=<DSH版本> TARBALL_ARCH=amd64 bash scripts/apps/deepseek-harness/build.sh
  bash build-fpk.sh <FPK版本> x86
  ```
- **CI 脚本**位于 `scripts/ci/`，由 `.github/workflows/build-and-release.yml` 调用；版本兜底值等构建元数据统一在 `scripts/apps/deepseek-harness/meta.env` 维护。

---

## 📄 开源许可

本项目遵循 MIT 开源许可证。
