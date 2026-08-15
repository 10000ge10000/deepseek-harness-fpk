#!/bin/bash
set -e

# Build DeepSeek Harness app.tgz for fnOS (.fpk)
# Strategy: bundle Node.js runtime + pre-installed node_modules + proxy + ui assets (offline-ready, version-locked)
# Reference: apps/feigram from conversun/fnos-apps

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

VERSION="${VERSION:-0.1.0-rc.6}"
NODE_VERSION="${NODE_VERSION:-24.4.0}"
TARBALL_ARCH="${TARBALL_ARCH:-amd64}"
OUTPUT_TGZ="${OUTPUT_TGZ:-${REPO_ROOT}/app_${TARBALL_ARCH}.tgz}"

case "$TARBALL_ARCH" in
  amd64|x86|x64) NODE_ARCH="x64" ;;
  arm64|aarch64|arm) NODE_ARCH="arm64" ;;
  *) echo "Unsupported TARBALL_ARCH=${TARBALL_ARCH}" >&2; exit 1 ;;
esac

NODE_ARCHIVE="node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"
NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_ARCHIVE}"

echo "==> Building DeepSeek Harness ${VERSION} for ${TARBALL_ARCH} (Node ${NODE_VERSION})"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# 1. Download Node.js runtime
echo "==> Downloading Node.js ${NODE_VERSION}..."
curl -fL --retry 3 -o "${WORK_DIR}/${NODE_ARCHIVE}" "$NODE_URL"
mkdir -p "${WORK_DIR}/node"
tar -xJf "${WORK_DIR}/${NODE_ARCHIVE}" -C "${WORK_DIR}/node" --strip-components=1

# 2. Install dsh (npm package, includes all deps)
mkdir -p "${WORK_DIR}/dsh-web"
cd "${WORK_DIR}/dsh-web"
"${WORK_DIR}/node/bin/npm" init -y >/dev/null 2>&1
echo "==> Installing @deepseek-ai/dsh@${VERSION}..."
"${WORK_DIR}/node/bin/npm" install "@deepseek-ai/dsh@${VERSION}" --omit=dev --no-audit --no-fund

# 3. Assemble app_root (app.tgz content)
mkdir -p "${WORK_DIR}/app_root/bin"
cp "${WORK_DIR}/node/bin/node" "${WORK_DIR}/app_root/bin/node"
chmod +x "${WORK_DIR}/app_root/bin/node"
cp -a "${WORK_DIR}/dsh-web/node_modules" "${WORK_DIR}/app_root/node_modules"
cp "${WORK_DIR}/dsh-web/package.json" "${WORK_DIR}/app_root/package.json" 2>/dev/null || true

# 复制 ui 目录和启动/反代脚本至 app_root (解压后位于 ${TRIM_APPDEST})
if [ -d "${REPO_ROOT}/apps/deepseek-harness/fnos/ui" ]; then
    echo "==> Bundling desktop UI config..."
    cp -r "${REPO_ROOT}/apps/deepseek-harness/fnos/ui" "${WORK_DIR}/app_root/ui"
fi
if [ -d "${REPO_ROOT}/apps/deepseek-harness/fnos/bin" ]; then
    echo "==> Bundling start & proxy scripts..."
    cp -r "${REPO_ROOT}/apps/deepseek-harness/fnos/bin/." "${WORK_DIR}/app_root/bin/"
    chmod +x "${WORK_DIR}/app_root/bin/"* 2>/dev/null || true
fi

# 4. 执行独立补丁脚本（前端非安全上下文 UUID、403 放行、一万AI分享单模型与飞牛工作区补丁）
python3 "${SCRIPT_DIR}/patch.py" "${WORK_DIR}/app_root"

# 5. Build app.tgz
tar -czf "${OUTPUT_TGZ}" -C "${WORK_DIR}/app_root" .
cp "${OUTPUT_TGZ}" "${REPO_ROOT}/app.tgz" 2>/dev/null || true
echo "==> Built ${OUTPUT_TGZ} for DeepSeek Harness ${VERSION}"
du -h "${OUTPUT_TGZ}"