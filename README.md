# DeepSeek Harness for fnOS (飞牛私有云 NAS)

[![Build and Release DeepSeek Harness FPK](https://github.com/10000ge10000/deepseek-harness-fpk/actions/workflows/build-and-release.yml/badge.svg)](https://github.com/10000ge10000/deepseek-harness-fpk/actions/workflows/build-and-release.yml)

本项目为 **DeepSeek Harness** 在 **飞牛私有云 NAS (fnOS)** 上的专属定制离线安装包（`.fpk`）及自动构建流水线。

---

## 🌟 定制特性

1. **一键开箱即用（一万AI分享专属定制）**：
   - 基于上游最新正式基线 `@deepseek-ai/dsh` **0.1.5-rc.1** 原生适配，完整支持 Cordis Profile 架构与 Bundle 体系。
   - 内置公益站点 API 端点：`https://api.910501.xyz/v1`
   - 预制模型提供商在设置中显示为 **一万AI分享**；内部兼容 DeepSeek 官方路由，不会把用户已有配置改名或锁定。
   - 完备内置 4 款官方模型目录（`deepseek-flash` 多模态默认模型、`deepseek-v4-flash`、`deepseek-v4-pro`、`deepseek-v4-flash-vision-exp`），默认上下文收敛锁定为 200K，输出上限收敛为 64K。
   - 模型、Base URL 和 API Key 均可自由编辑；支持多模型自由切换，保留并完全兼容用户自定义 Provider 与自定义模型。
   - 安装向导仅需输入 API Key（可跳过），完全无需复杂参数配置。
2. **极简 2 步安装向导**：
   - 包含一键直达公益站及 B 站视频教程超链接。
   - 移除多余的端口交互（内置安全固定内部端口 3081 与外部透明反代端口 3080）。
3. **工作区与飞牛桌面【文件管理】100% 同步互通**：
   - 应用数据目录直接与飞牛桌面【文件管理】$\rightarrow$【应用文件】$\rightarrow$【`DeepSeekHarness`】桥接。
   - 在应用内创建的工程、项目代码、文件实时可见，支持在线管理与下载。
   - 动态识别 `/vol1`、`/vol2`、`/vol3` 等多存储卷，目录选择器与权限模型安全隔离。
4. **插件与扩展生态完整支持**：
   - 内置捆绑 `pnpm` 包管理器，随应用提供 `bin/dsh` 命令行包装器。
   - 支持通过 `dsh plugin --profile web` 自由安装、更新和卸载第三方插件，配置与插件模块于 `$DSH_HOME/profiles/web/` 持久化保存。
5. **局域网环境无缝支持**：
   - 内置安全上下文 Polyfill 与透明反向代理支持，完美适配 HTTP / 局域网非安全上下文环境。
   - 自动适配飞牛桌面 iframe 嵌入认证与 SameSite=Lax Cookie 策略。

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
