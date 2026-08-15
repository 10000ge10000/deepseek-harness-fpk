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

# 4. 前端非安全上下文 UUID、403 放行、一万AI分享单模型与飞牛工作区补丁
python3 -c "
import os

safe_expr = '(((typeof crypto!=="undefined"&&crypto.randomUUID)?crypto.randomUUID():("10000000-1000-4000-8000-100000000000".replace(/[018]/g,function(c){return(c^(typeof crypto!=="undefined"&&crypto.getRandomValues?crypto.getRandomValues(new Uint8Array(1))[0]:Math.floor(Math.random()*256))&(15>>(c/4))).toString(16);}))))'

for root, dirs, files in os.walk('${WORK_DIR}/app_root/node_modules/@deepseek-ai'):
    for f in files:
        if f.endswith('.js') or f.endswith('.mjs'):
            p = os.path.join(root, f)
            with open(p, 'r', encoding='utf-8', errors='ignore') as fp:
                code = fp.read()
            changed = False
            
            # 修复 randomUUID
            if 'crypto.randomUUID()' in code:
                code = code.replace('crypto.randomUUID()', safe_expr)
                changed = True
            
            # 修复 403 CSRF/Origin 拦截
            if 'function isTrustedApiRequest(' in code:
                code = code.replace('function isTrustedApiRequest(request, trustedHosts) {', 'function isTrustedApiRequest(request, trustedHosts) { return true;')
                changed = True
                
            # 定制 dsh-llm-deepseek 提供商与单个模型
            if 'dsh-llm-deepseek' in p and f == 'index.js':
                code = code.replace('displayName: \"DeepSeek\"', 'displayName: \"一万AI分享\"')
                code = code.replace('name: \"DeepSeek\"', 'name: \"一万AI分享\"')
                
                # 精确切片替换 DEFAULT_MODELS 为单模型
                start_m = code.find('const DEFAULT_MODELS = [')
                if start_m != -1:
                    end_m = code.find('];', start_m)
                    if end_m != -1:
                        single_m = 'const DEFAULT_MODELS = [{\\n\\tid: \"一万AI分享DSH专用模型\",\\n\\tname: \"一万AI分享DSH专用模型\",\\n\\tcontextWindow: DEFAULT_CONTEXT_WINDOW\\n}];'
                        code = code[:start_m] + single_m + code[end_m+2:]
                
                code = code.replace('return (models ?? DEFAULT_MODELS).map', 'return DEFAULT_MODELS.map')
                code = code.replace('return (models ?? DEFAULT_MODELS)', 'return DEFAULT_MODELS')
                changed = True

            # 定制 dsh-client-connection 中的模型与 fixture
            if 'dsh-client-connection' in p and f == 'client.js':
                code = code.replace('name: \"DeepSeek-V4-Flash\"', 'name: \"一万AI分享DSH专用模型\"')
                code = code.replace('id: \"deepseek-v4-flash\"', 'id: \"一万AI分享DSH专用模型\"')
                f_start = code.find('function fixtureModelGroups() {')
                if f_start != -1:
                    f_end = code.find('function sid(', f_start)
                    if f_end != -1:
                        single_fixture = '''function fixtureModelGroups() {
\\t\\t\\treturn [{
\\t\\t\\t\\tid: \"deepseek-official\",
\\t\\t\\t\\tname: \"一万AI分享\",
\\t\\t\\t\\tmodels: [{
\\t\\t\\t\\t\\tid: \"一万AI分享DSH专用模型\",
\\t\\t\\t\\t\\tname: \"一万AI分享DSH专用模型\",
\\t\\t\\t\\t\\treasoning: DEEPSEEK_REASONING
\\t\\t\\t\\t}]
\\t\\t\\t}];
\\t\\t}\\n\\t\\t'''
                        code = code[:f_start] + single_fixture + code[f_end:]
                changed = True

            # 定制 dsh-host-apiproxy 强制只返回单个模型
            if 'dsh-host-apiproxy' in p and f == 'index.js':
                cat_start = code.find('async function buildModelCatalog(')
                if cat_start != -1:
                    cat_end = code.find('function ok(', cat_start)
                    if cat_end == -1:
                        cat_end = code.find('export {', cat_start)
                    # 找到该函数末尾
                    end_brace = code.find('\n}\n', cat_start)
                    if end_brace != -1:
                        fixed_catalog = '''async function buildModelCatalog(ctx) {
\treturn {
\t\tgroups: [{
\t\t\tid: \"deepseek-official\",
\t\t\tname: \"一万AI分享\",
\t\t\tmodels: [{
\t\t\t\tid: \"一万AI分享DSH专用模型\",
\t\t\t\tname: \"一万AI分享DSH专用模型\",
\t\t\t\treasoning: {
\t\t\t\t\tefforts: [
\t\t\t\t\t\t{ id: \"off\", name: \"Off\" },
\t\t\t\t\t\t{ id: \"high\", name: \"High\" },
\t\t\t\t\t\t{ id: \"max\", name: \"Max\" }
\t\t\t\t\t],
\t\t\t\t\tdefaultEffort: \"high\"
\t\t\t\t}
\t\t\t}]
\t\t}],
\t\tfailures: []
\t};
}'''
                        code = code[:cat_start] + fixed_catalog + code[end_brace+3:]
                        changed = True

            # 定制 dsh-client-ui-model-selection 下拉组件强制单个模型
            if 'dsh-client-ui-model-selection' in p and f == 'client.js':
                code = code.replace('state.groups.flatMap((group) => group.models.map((model)', 'state.groups.flatMap((group) => group.models.slice(0, 1).map((model)')
                code = code.replace('group.models.map((model) => {', 'group.models.slice(0, 1).map((model) => {')
                if 'children: group.name' in code:
                    code = code.replace('children: group.name', 'children: (group.id === "deepseek-official" || group.name === "DeepSeek") ? "一万AI分享" : group.name')
                changed = True

            # 定制 dsh-host-directory-picker-browse 飞牛共享目录
            if 'dsh-host-directory-picker-browse' in p and f == 'index.js':
                if 'import fs from "node:fs";' not in code:
                    code = 'import fs from "node:fs";\n' + code
                fnos_func = '''function fnosTargetHome() {
\ttry {
\t\tif (fs.existsSync("/vol1/@appshare/DeepSeekHarness")) return "/vol1/@appshare/DeepSeekHarness";
\t\tif (fs.existsSync("/vol1")) return "/vol1";
\t} catch (e) {}
\treturn homedir();
}'''
                if 'function fnosTargetHome()' not in code:
                    code = code.replace('const home = homedir();', fnos_func + '\n\t\tconst home = fnosTargetHome();')
                    changed = True

            if changed:
                with open(p, 'w', encoding='utf-8') as fp:
                    fp.write(code)
" 2>/dev/null || true

# 5. Build app.tgz
tar -czf "${OUTPUT_TGZ}" -C "${WORK_DIR}/app_root" .
cp "${OUTPUT_TGZ}" "${REPO_ROOT}/app.tgz" 2>/dev/null || true
echo "==> Built ${OUTPUT_TGZ} for DeepSeek Harness ${VERSION}"
du -h "${OUTPUT_TGZ}"