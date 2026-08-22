#!/usr/bin/env bash
set -euo pipefail

# 构建单一架构的 .fpk（由 workflow 的 build / build_arm job 调用）。
# 环境变量：
#   DSH_VERSION    上游 DSH npm 版本（必传。必须显式传递，防止 build.sh
#                  静默重查 npm 造成 FPK 文件名版本与包内 DSH 版本错位）
#   TARGET_VERSION FPK 版本号（必传，写入 manifest）
#   TARBALL_ARCH   amd64 | arm64
#   FPK_PLATFORM   x86 | arm

# scripts/ci/ 距仓库根只有两级，与 scripts/apps/<app>/ 的三级不同
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# 供测试断言路径解析，不做任何构建动作
if [ "${1:-}" = "--print-root" ]; then
    echo "${REPO_ROOT}"
    exit 0
fi

if [ -z "${DSH_VERSION:-}" ] || [ -z "${TARGET_VERSION:-}" ]; then
    echo "DSH_VERSION 与 TARGET_VERSION 必须显式传递（CI 模式禁止静默解析 npm）" >&2
    exit 1
fi

TARBALL_ARCH="${TARBALL_ARCH:-amd64}"
FPK_PLATFORM="${FPK_PLATFORM:-x86}"

chmod +x "${REPO_ROOT}/scripts/apps/deepseek-harness/build.sh" "${REPO_ROOT}/build-fpk.sh"
echo "==> 构建 ${FPK_PLATFORM} 架构应用包 (DSH ${DSH_VERSION} -> FPK ${TARGET_VERSION})..."
VERSION="${DSH_VERSION}" TARBALL_ARCH="${TARBALL_ARCH}" bash "${REPO_ROOT}/scripts/apps/deepseek-harness/build.sh"
bash "${REPO_ROOT}/build-fpk.sh" "${TARGET_VERSION}" "${FPK_PLATFORM}"
