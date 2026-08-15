# 飞牛官方应用商店 (App Center) 提报上架申请指南

本项目已完全按照飞牛私有云（fnOS）官方 FPK 标准规范进行封装与测试。如果计划将应用提交至飞牛官方应用中心审核上架，可直接使用以下物料与指引。

---

## 📋 应用提报基础信息

| 字段名 | 提报内容 |
| :--- | :--- |
| **应用名称 (appname)** | `DeepSeekHarness` |
| **应用中文名** | `DeepSeek Harness` (一万AI分享定制版) |
| **版本号 (version)** | `0.1.0-rc.6.1` |
| **适用架构 (platform)** | `x86_64` (amd64) |
| **应用分类** | AI 工具 / 开发运维 |
| **开发者/发布者** | `一万AI分享` |
| **官方网站** | `https://api.910501.xyz` |
| **开源代码库** | `https://github.com/10000ge10000/deepseek-harness-fpk` |
| **一句话描述** | DeepSeek 官方 AI 开发助手与桌面工作台，开箱即用。 |
| **详细介绍** | DeepSeek Harness 是 DeepSeek 官方开源的 AI 本地工作台与编程助手。本项目为飞牛 NAS 提供深度适配，内置「一万AI分享」公益 API 接口与专属模型，并已彻底打通飞牛桌面【文件管理】中的应用工作区，支持在局域网内直接流畅调用。 |

---

## 📁 提报物料与清单

- **应用描述文件**：[`apps/deepseek-harness/fnos/manifest`](file:///apps/deepseek-harness/fnos/manifest)
- **权限与资源声明**：[`apps/deepseek-harness/fnos/config/privilege`](file:///apps/deepseek-harness/fnos/config/privilege) 和 [`resource`](file:///apps/deepseek-harness/fnos/config/resource)
- **图形界面与图标**：
  - 64x64 图标：[`apps/deepseek-harness/fnos/ICON.PNG`](file:///apps/deepseek-harness/fnos/ICON.PNG)
  - 256x256 高清图标：[`apps/deepseek-harness/fnos/ICON_256.PNG`](file:///apps/deepseek-harness/fnos/ICON_256.PNG)
- **安装向导文件**：[`apps/deepseek-harness/fnos/wizard/install`](file:///apps/deepseek-harness/fnos/wizard/install)
- **完整安装包**：[GitHub Releases 下载链接](https://github.com/10000ge10000/deepseek-harness-fpk/releases/latest)

---

## 🚀 官方上架提报流程

1. **进入飞牛开发者提报渠道**：
   - 方式 A：在飞牛官方开发者社区 / 飞牛官方论坛的【开发者专区】发布上架申请贴。
   - 方式 B：向飞牛官方应用中心代码仓库提交 PR（Pull Request），提交 `manifest` 及相关元数据。
2. **官方审核与自动化扫描**：
   - 飞牛官方系统会对 `.fpk` 进行沙箱隔离与端口规范性检查（本项目已内置独立 Node 运行时与反向代理，无多余网络暴露，符合规范）。
3. **审核通过并上架**：
   - 审核完成后，所有飞牛 NAS 用户即可在自带的【应用中心】内直接搜索并一键安装。
