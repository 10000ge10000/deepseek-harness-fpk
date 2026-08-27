#!/usr/bin/env bash
set -uo pipefail

# 零依赖测试套件：静态校验 + 关键逻辑回归单测。
# 在本地与 CI（ubuntu-latest）均可直接运行：bash tests/run-tests.sh

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "  ✓ $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  ✗ $1"; }
check(){ if [ "$1" -eq 0 ]; then ok "$2"; else bad "$2"; fi; }

echo "== 1. Shell 语法校验（bash -n）=="
# 只校验带 bash shebang 的脚本与 .sh 文件，避免误伤 PNG/JSON/配置等资源
SHELL_FILES=$(mktemp)
{
    find shared/cmd apps scripts tests -type f \( -name '*.sh' -o -name '*.sc' \) 2>/dev/null
    # 无扩展名脚本：按 shebang 识别
    find shared/cmd apps -type f ! -name '*.*' 2>/dev/null | while IFS= read -r f; do
        head -n 1 "$f" 2>/dev/null | grep -q '^#!.*bash' && printf '%s\n' "$f"
    done
} | sort -u > "$SHELL_FILES"
while IFS= read -r f; do
    if bash -n "$f" 2>/dev/null; then ok "$f"; else bad "$f"; fi
done < "$SHELL_FILES"

echo "== 2. JavaScript 语法校验（node --check）=="
if command -v node >/dev/null 2>&1; then
    node --check apps/deepseek-harness/fnos/bin/runner.js 2>/dev/null
    check $? "runner.js 语法"
else
    echo "  - 跳过：node 不可用"
fi

echo "== 3. Python 语法校验（py_compile）=="
if command -v python3 >/dev/null 2>&1; then
    python3 -m py_compile scripts/apps/deepseek-harness/patch.py scripts/ci/generate-appstore.py 2>/dev/null
    check $? "patch.py / generate-appstore.py 语法"
elif command -v python >/dev/null 2>&1; then
    python -m py_compile scripts/apps/deepseek-harness/patch.py scripts/ci/generate-appstore.py 2>/dev/null
    check $? "patch.py / generate-appstore.py 语法"
else
    echo "  - 跳过：python 不可用"
fi

echo "== 4. 端口 PID 提取回归（历史 bug：sed 替换组曾为 0x01 控制字符）=="
NETSTAT_LINE='tcp        0      0 0.0.0.0:3080            0.0.0.0:*               LISTEN      12345/node          '
GOT=$(printf '%s\n' "$NETSTAT_LINE" | sed -n 's/.*[[:space:]]\([0-9]\+\)\/[A-Za-z0-9_+.-]*[[:space:]]*$/\1/p')
[ "$GOT" = "12345" ]
check $? "netstat 行提取 PID=12345（实际: ${GOT:-空}）"

# 源码中不得再出现 0x01 控制字符（仅检查文本脚本，PNG 等二进制除外）
if grep -q $'\x01' $(cat "$SHELL_FILES") scripts/apps/deepseek-harness/patch.py scripts/ci/generate-appstore.py 2>/dev/null; then
    bad "源码中存在 0x01 控制字符残留"
else
    ok "源码无 0x01 控制字符残留"
fi
rm -f "$SHELL_FILES"

echo "== 5. 端口匹配模式（PORT_PATTERN）=="
SERVICE_PORT=3080
INTERNAL_PORT=3081
PORT_PATTERN=":(${SERVICE_PORT}|${INTERNAL_PORT}) "
printf '0.0.0.0:3080 \n' | grep -qE "${PORT_PATTERN}"
check $? "匹配 3080"
printf '127.0.0.1:3081 \n' | grep -qE "${PORT_PATTERN}"
check $? "匹配 3081"
if printf '0.0.0.0:30801 \n' | grep -qE "${PORT_PATTERN}"; then
    bad "30801 不应被匹配（前缀碰撞）"
else
    ok "30801 不被误匹配"
fi

echo "== 6. load_variables_from_file 行为（注释/空行/非法键/值含等号）=="
if command -v bash >/dev/null 2>&1; then
    TESTDIR=$(mktemp -d)
    cat > "${TESTDIR}/vars" <<'EOF'
# 全行注释
   # 带缩进注释

FOO=bar baz
QUX=a=b=c
1bad=x
bad key=x
EMPTY=
EOF
    rc_holder=$(TRIM_APPNAME=dsh-unittest TRIM_PKGVAR="/vol1/@appdata/dsh-unittest" TESTDIR="${TESTDIR}" bash -c '
        mkdir -p "${TRIM_PKGVAR}" 2>/dev/null || true
        export TESTDIR
        source shared/cmd/common >/dev/null 2>&1 || exit 9
        load_variables_from_file "${TESTDIR}/vars"
        rc=0
        [ "${FOO:-}" = "bar baz" ] || rc=1
        [ "${QUX:-}" = "a=b=c" ] || rc=2
        # ${VAR-default} 仅在未设置时取默认；${VAR:-default} 对空值也取默认
        [ "${EMPTY-UNSET}" = "" ] || rc=3
        declare -p 1bad >/dev/null 2>&1 && rc=4
        [ "${NOTSET:-}" = "" ] || rc=5
        exit $rc' 2>/dev/null; echo $?)
    case "$rc_holder" in
        0) ok "合法键正确导出（含空格值与等号值）" ;;
        9) bad "common 加载失败" ;;
        *) bad "load_variables 行为不符预期 (rc=${rc_holder})" ;;
    esac
    rm -rf "${TESTDIR}"
fi

echo "== 7. generate-appstore.py 产出校验 =="
PY_BIN=""
if command -v python3 >/dev/null 2>&1; then PY_BIN=python3
elif command -v python >/dev/null 2>&1; then PY_BIN=python
fi
if [ -n "$PY_BIN" ]; then
    OUTDIR=$(mktemp -d)
    PKGDIR=$(mktemp -d)
    # 构造带真实字节的假安装包，用于校验 sha256/size 一致性
    # 假包 ≥1MB 以覆盖顶层 size 的 MB 取整逻辑（zero 生成快且哈希真实）
    head -c 104857600 /dev/zero > "${PKGDIR}/dsh_1.2.3_x86.fpk"
    head -c 52428800 /dev/zero > "${PKGDIR}/dsh_1.2.3_arm.fpk"
    if GITHUB_REPOSITORY=someone/fork-test "$PY_BIN" scripts/ci/generate-appstore.py \
        --version 1.2.3 --tag v1.2.3 \
        --x86-fpk dsh_1.2.3_x86.fpk --arm-fpk dsh_1.2.3_arm.fpk \
        --out-dir "${OUTDIR}" --pkg-dir "${PKGDIR}" >/dev/null 2>&1; then
        ok "脚本执行成功"
        "$PY_BIN" - "$OUTDIR" "${PKGDIR}" <<'PYEOF' 2>/dev/null
import json, sys, os, hashlib
out, pkgdir = sys.argv[1], sys.argv[2]
data = json.load(open(os.path.join(out, 'appstore.json'), encoding='utf-8'))
assert len(data['apps']) == 2, 'apps 数量'
x86 = [a for a in data['apps'] if a['platform'] == 'x86'][0]
assert x86['download_url'].endswith('/dsh_1.2.3_x86.fpk'), 'x86 下载链接'
assert 'someone/fork-test' in x86['download_url'], '仓库 slug 来自 GITHUB_REPOSITORY'
assert 'someone/fork-test' in x86['icon'], 'icon 链接同样参数化'
html = open(os.path.join(out, 'index.html'), encoding='utf-8').read()
assert 'dsh_1.2.3_arm.fpk' in html, 'HTML 含 ARM 下载文件名'
assert 'fnpack.json' in html, 'HTML 含 FnDepot 源地址卡片'

# FnDepot V2 格式校验（严格 JSON + 关键字段 + 指纹一致性）
raw = open(os.path.join(out, 'fnpack.json'), encoding='utf-8').read()
fp = json.loads(raw)  # 严格解析：注释/尾逗号会抛异常
assert fp['schema_version'] == '2' and isinstance(fp['schema_version'], str), 'schema_version 必须是字符串 "2"'
app = fp['apps']['deepseek-harness']
assert app['platform'] == ['x86', 'arm'], 'platform'
assert app['categories'] == ['AI赋能'], 'categories'
assert app['run_as'] == 'package' and app['is_docker'] is False, '运行声明'
# 兼容字段：FnDepot 0.0.7 校验必需（曾因缺失顶层 version 报"json 源格式无效"，
# 缺 download_url 报"JSON 直链源必须提供"）
assert app['version'] == '1.2.3', '应用节点顶层 version'
assert app['author'] and app['distributor'], '发布者字段'
assert app['download_url'].endswith('dsh_1.2.3_x86.fpk'), '顶层 download_url'
assert isinstance(app['size'], int) and 0 < app['size'] < 1024, '顶层 size 为 MB 取整'
rel = app['releases']['1.2.3']
for arch, fname in (('x86', 'dsh_1.2.3_x86.fpk'), ('arm', 'dsh_1.2.3_arm.fpk')):
    p = rel['packages'][arch]
    blob = open(os.path.join(pkgdir, fname), 'rb').read()
    assert p['sha256'] == hashlib.sha256(blob).hexdigest(), f'{arch} sha256 与真实文件一致'
    assert p['size'] == len(blob), f'{arch} size 与真实文件一致'
    assert 'someone/fork-test' in p['download_url'], f'{arch} 链接参数化'
PYEOF
        check $? "JSON/HTML/fnpack 内容与 fork 参数化正确"
    else
        bad "脚本执行失败"
    fi
    rm -rf "${OUTDIR}" "${PKGDIR}"
else
    echo "  - 跳过：python 不可用"
fi

echo "== 8. CI 脚本路径解析（历史 bug：REPO_ROOT 曾多算一级）=="
GOT_ROOT=$(cd /tmp && bash "${REPO_ROOT}/scripts/ci/build-package.sh" --print-root)
if [ "${GOT_ROOT}" = "${REPO_ROOT}" ]; then
    ok "build-package.sh REPO_ROOT 解析正确"
else
    bad "REPO_ROOT 解析错误: 期望 ${REPO_ROOT} 实际 ${GOT_ROOT}"
fi

echo "== 9. patch.py 补丁命中/漂移拒绝/幂等（上游自动适配的安全网）=="
PY_BIN2=""
if command -v python3 >/dev/null 2>&1; then PY_BIN2=python3
elif command -v python >/dev/null 2>&1; then PY_BIN2=python
fi
if [ -n "$PY_BIN2" ]; then
    FIX=$(mktemp -d)
    mkdir -p "${FIX}/hit/node_modules/@deepseek-ai/dsh-server" \
             "${FIX}/hit/node_modules/@deepseek-ai/dsh-client-connection" \
             "${FIX}/hit/node_modules/@deepseek-ai/dsh-llm-deepseek" \
             "${FIX}/hit/node_modules/@deepseek-ai/dsh-host-directory-picker-browse" \
             "${FIX}/drift/node_modules/@deepseek-ai/dsh-server"
    # 命中夹具：包含全部补丁目标字符串；模型目录块用 printf 生成，
    # \t 由 printf 解释为真实 tab，与上游生成物的缩进字节一致
    cat > "${FIX}/hit/node_modules/@deepseek-ai/dsh-server/index.js" <<'EOF'
function isTrustedApiRequest(request, trustedHosts) {
  return false;
}
function isLoopbackHostname(hostname) {
  return hostname === "127.0.0.1";
}
EOF
    printf 'const conn = { isLoopback: pageLocation === void 0 || isLoopbackHostname(pageLocation.hostname), id: "deepseek-official", name: "DeepSeek" };\n' \
        > "${FIX}/hit/node_modules/@deepseek-ai/dsh-client-connection/client.js"
    {
        printf 'export default { name: "DeepSeek", displayName: "DeepSeek" };\n'
        printf 'const DEFAULT_CONTEXT_WINDOW = 1e6;\n'
        printf 'const DEFAULT_MAX_TOKENS = 256e3;\n'
        printf 'const resolved = { maxTokens: config.maxTokens ?? 256e3 };\n'
        printf 'const DEFAULT_MODELS = [\n\t{\n\t\tid: "deepseek-v4-flash",\n\t\tname: "DeepSeek-V4-Flash",\n\t\tcontextWindow: DEFAULT_CONTEXT_WINDOW\n\t},\n\t{\n\t\tid: "deepseek-v4-pro",\n\t\tname: "DeepSeek-V4-Pro",\n\t\tcontextWindow: DEFAULT_CONTEXT_WINDOW\n\t},\n\t{\n\t\tid: "deepseek-v4-flash-vision-exp",\n\t\tname: "DeepSeek-V4-Flash-Vision-Exp",\n\t\tcontextWindow: DEFAULT_CONTEXT_WINDOW,\n\t\tinputModalities: ["text", "image"],\n\t\timagePixelBudget: DEFAULT_REQUEST_IMAGE_PIXEL_BUDGET,\n\t\timageMaxBytes: DEFAULT_REQUEST_IMAGE_MAX_BYTES\n\t}\n];\n'
    } > "${FIX}/hit/node_modules/@deepseek-ai/dsh-llm-deepseek/index.js"
    # 目录选择器夹具：严格照上游 rc.2 形态——只具名导入 node:fs/promises，
    # 没有 fs 默认绑定。此前夹具缺失该包，导致注入的 fnosTargetHome 用了
    # fs.existsSync 却没补 import fs 的回归一路溜到 rc.8 与 rc.2 两个发布版
    # （运行时 ReferenceError 被 try/catch 吞掉，静默回落 homedir）。
    {
        printf 'import { mkdir, opendir, stat } from "node:fs/promises";\n'
        printf 'import { homedir } from "node:os";\n'
        printf 'const home = homedir();\n'
    } > "${FIX}/hit/node_modules/@deepseek-ai/dsh-host-directory-picker-browse/index.js"
    # 漂移夹具：上游改版后目标串全部消失
    printf 'function isTrustedApiRequest(req){return verify(req);}\n' \
        > "${FIX}/drift/node_modules/@deepseek-ai/dsh-server/index.js"

    if "$PY_BIN2" "${REPO_ROOT}/scripts/apps/deepseek-harness/patch.py" "${FIX}/hit" >/dev/null 2>&1; then
        ok "补丁全部命中 → 退出码 0"
    else
        bad "命中夹具被误判失败"
    fi
    if grep -q 'isLoopbackHostname(hostname) { return true;' "${FIX}/hit/node_modules/@deepseek-ai/dsh-server/index.js" \
       && grep -q 'isLoopback: true, // fnOS fix' "${FIX}/hit/node_modules/@deepseek-ai/dsh-client-connection/client.js" \
       && grep -q '一万AI分享' "${FIX}/hit/node_modules/@deepseek-ai/dsh-llm-deepseek/index.js" \
       && grep -q 'const DEFAULT_CONTEXT_WINDOW = 2e5;' "${FIX}/hit/node_modules/@deepseek-ai/dsh-llm-deepseek/index.js" \
       && grep -q 'name: "一万AI分享DSH专用模型"' "${FIX}/hit/node_modules/@deepseek-ai/dsh-llm-deepseek/index.js" \
       && grep -q 'const DEFAULT_MAX_TOKENS = 65536;' "${FIX}/hit/node_modules/@deepseek-ai/dsh-llm-deepseek/index.js" \
       && grep -q 'config.maxTokens ?? 65536' "${FIX}/hit/node_modules/@deepseek-ai/dsh-llm-deepseek/index.js" \
       && ! grep -q 'deepseek-v4-pro' "${FIX}/hit/node_modules/@deepseek-ai/dsh-llm-deepseek/index.js"; then
        ok "关键补丁、改名与单一品牌模型目录实际生效"
    else
        bad "补丁内容未正确写入"
    fi
    # 目录选择器：fnosTargetHome 用同步 fs.existsSync，必须有配套的 fs 默认导入。
    # 缺这行时 node --check 仍通过（语法合法），但运行时 fs 未定义 → 静默回落
    # homedir()，飞牛共享目录定制完全失效。断言三项：注入生效、导入补上、单例。
    PICKER="${FIX}/hit/node_modules/@deepseek-ai/dsh-host-directory-picker-browse/index.js"
    PICKER_IMPORTS=$(grep -cE '^import fs from "node:fs";$' "$PICKER" 2>/dev/null)
    PICKER_HOMES=$(grep -oE 'const home =' "$PICKER" 2>/dev/null | wc -l)
    if grep -q 'const home = fnosTargetHome();' "$PICKER" \
       && [ "$PICKER_IMPORTS" = "1" ] \
       && [ "$(printf '%s' "$PICKER_HOMES" | tr -d ' ')" = "1" ]; then
        ok "目录选择器注入生效且 fs 默认导入已补齐（单例）"
    else
        bad "目录选择器补丁异常（fs 导入=${PICKER_IMPORTS}，home 赋值=${PICKER_HOMES}）"
    fi
    # 幂等：二次执行不应因『未再替换』而误报失败
    if "$PY_BIN2" "${REPO_ROOT}/scripts/apps/deepseek-harness/patch.py" "${FIX}/hit" >/dev/null 2>&1; then
        ok "重复执行（幂等）不误报"
    else
        bad "幂等性被破坏"
    fi
    # 漂移：上游改版后必须拒绝打包
    if "$PY_BIN2" "${REPO_ROOT}/scripts/apps/deepseek-harness/patch.py" "${FIX}/drift" >/dev/null 2>&1; then
        bad "上游漂移未被发现（危险：会发布局域网不可用的包）"
    else
        ok "上游漂移 → 拒绝打包（退出码非 0）"
    fi
    rm -rf "${FIX}"
else
    echo "  - 跳过：python 不可用"
fi

echo "== 10. build-fpk.sh 最小冒烟（假 app.tgz 组装结构）=="
SMOKE_DIR=$(mktemp -d)
trap 'rm -rf "${SMOKE_DIR}"; rm -f "${REPO_ROOT}/deepseek-harness_9.9.9-test_x86.fpk" "${REPO_ROOT}/app.tgz"' EXIT
mkdir -p "${SMOKE_DIR}/approot/bin"
echo "fake-node" > "${SMOKE_DIR}/approot/bin/node"
tar --owner=0 --group=0 --numeric-owner -czf "${REPO_ROOT}/app.tgz" -C "${SMOKE_DIR}/approot" .
if OUT=$(bash build-fpk.sh 9.9.9-test x86 2>&1); then
    ok "build-fpk.sh 构建成功"
    FPK="deepseek-harness_9.9.9-test_x86.fpk"
    if [ -f "${REPO_ROOT}/${FPK}" ]; then ok "产物文件存在"; else bad "产物文件缺失"; fi
    # 先取完整列表再匹配：grep -q 提前退出会让 tar 收 SIGPIPE，
    # 在 set -o pipefail 下管道被误判为失败
    FPK_LISTING=$(tar -tzf "${REPO_ROOT}/${FPK}" 2>/dev/null)
    if grep -q '^manifest$' <<<"$FPK_LISTING"; then ok "包含 manifest"; else bad "缺少 manifest"; fi
    if grep -q '^app.tgz$' <<<"$FPK_LISTING"; then ok "包含 app.tgz"; else bad "缺少 app.tgz"; fi
    if tar -xzOf "${REPO_ROOT}/${FPK}" manifest 2>/dev/null | grep -q '^version.*9\.9\.9-test'; then
        ok "manifest 版本号注入正确"
    else
        bad "manifest 版本号注入失败"
    fi
else
    bad "build-fpk.sh 失败: ${OUT}"
fi

echo "== 11. 入口收敛门控（仅飞牛桌面 iframe 可进入）=="
if command -v node >/dev/null 2>&1; then
    node - <<'NODEEOF' 2>&1
const fs = require('fs');
const src = fs.readFileSync('apps/deepseek-harness/fnos/bin/runner.js', 'utf8');
// 门控的 4 个函数在 runner.js 里是连续的一段，按边界整段取出后单独求值，
// 避免 require 触发 runner.js 顶层的启动副作用（spawn dsh、监听端口）
const start = src.indexOf('function hostnameFromHostHeader(');
const end = src.indexOf('// 创建透明反代服务');
if (start === -1 || end === -1 || end <= start) {
    console.log('  ✗ 无法从 runner.js 提取门控函数（边界标记变更？）');
    process.exit(1);
}
const block = src.slice(start, end);
const { isAllowedRequest } = new Function(
    block + '\nreturn { isAllowedRequest };'
)();

const NAS = '10.10.10.10:3080';
const PANEL = 'http://10.10.10.10:5666/';
const cases = [
    // [用例名, 请求, 期望放行]
    ['地址栏直连：document 且无 Referer → 拦截',
        { method: 'GET', headers: { host: NAS, 'sec-fetch-dest': 'document', accept: 'text/html' } }, false],
    ['飞牛桌面 iframe 首次导航 → 放行',
        { method: 'GET', headers: { host: NAS, 'sec-fetch-dest': 'iframe', referer: PANEL, accept: 'text/html' } }, true],
    ['iframe 内子资源（script）→ 放行',
        { method: 'GET', headers: { host: NAS, 'sec-fetch-dest': 'script', referer: 'http://10.10.10.10:3080/' } }, true],
    ['应用内 fetch（dest=empty）→ 放行',
        { method: 'POST', headers: { host: NAS, 'sec-fetch-dest': 'empty' } }, true],
    ['WebSocket 握手（只发 Origin 不发 Referer）→ 放行',
        { method: 'GET', headers: { host: NAS, 'sec-fetch-dest': 'websocket', origin: 'http://10.10.10.10:3080' } }, true],
    ['外站链接跳入：Referer 主机名不匹配 → 拦截',
        { method: 'GET', headers: { host: NAS, 'sec-fetch-dest': 'document', referer: 'http://evil.example/', accept: 'text/html' } }, false],
    ['老 WebView 无 Sec-Fetch：HTML GET 无 Referer → 拦截',
        { method: 'GET', headers: { host: NAS, accept: 'text/html,application/xhtml+xml' } }, false],
    ['老 WebView 无 Sec-Fetch：HTML GET 带同主机 Referer → 放行',
        { method: 'GET', headers: { host: NAS, accept: 'text/html', referer: PANEL } }, true],
    ['老 WebView 无 Sec-Fetch：JSON 接口请求 → 放行',
        { method: 'POST', headers: { host: NAS, accept: 'application/json' } }, true],
    // 门控目标是拦住浏览器误入，不是防命令行伪造：真实浏览器发起顶层导航时
    // 必定带 Sec-Fetch-Dest: document 或 Accept: text/html，而裸 curl 两者皆无，
    // 判定为非导航而放行。此用例固化该取舍，避免日后被误读为漏洞。
    ['裸 curl（Accept: */* 且无 Sec-Fetch）→ 放行（非导航）',
        { method: 'GET', headers: { host: NAS, accept: '*/*' } }, true],
    ['IPv6 Host 与 Referer 主机名一致 → 放行',
        { method: 'GET', headers: { host: '[::1]:3080', 'sec-fetch-dest': 'iframe', referer: 'http://[::1]:5666/', accept: 'text/html' } }, true],
    ['畸形 Referer → 拦截',
        { method: 'GET', headers: { host: NAS, 'sec-fetch-dest': 'document', referer: 'not a url', accept: 'text/html' } }, false],
    ['缺 Host 头 → 拦截',
        { method: 'GET', headers: { 'sec-fetch-dest': 'document', referer: PANEL, accept: 'text/html' } }, false],
];

let failed = 0;
for (const [name, req, want] of cases) {
    let got;
    try {
        got = isAllowedRequest(req);
    } catch (e) {
        console.log(`  ✗ ${name}（抛异常: ${e.message}）`);
        failed++;
        continue;
    }
    if (got === want) {
        console.log(`  ✓ ${name}`);
    } else {
        console.log(`  ✗ ${name}（期望 ${want} 实际 ${got}）`);
        failed++;
    }
}
process.exit(failed === 0 ? 0 : 1);
NODEEOF
    GATE_RC=$?
    # 子进程已逐条打印明细，这里只把整节结果并入总计
    check "$GATE_RC" "门控判定矩阵（13 个用例）"
else
    echo "  - 跳过：node 不可用"
fi

echo "== 12. 发布策略判定（dry-run 必须只构建不发布）=="
# 用桩替换 npm / gh，使判定离线且确定：npm 查询返回固定版本、gh 模拟 Release 已存在
STUB=$(mktemp -d)
cat > "${STUB}/npm" <<'EOF'
#!/bin/sh
case "$*" in
  *dist-tags.next*)   echo "0.1.1-rc.2" ;;
  *dist-tags.latest*) echo "0.1.1-rc.2" ;;
  *) exit 0 ;;
esac
EOF
cat > "${STUB}/gh" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "${STUB}/npm" "${STUB}/gh"

resolve_policy() {
    env PATH="${STUB}:$PATH" GITHUB_OUTPUT="" \
        GITHUB_REPOSITORY=owner/repo "$@" \
        bash scripts/ci/resolve-version.sh 2>&1 | tail -1
}
expect_policy() {
    local desc="$1" want_build="$2" want_publish="$3"; shift 3
    local out; out=$(resolve_policy "$@")
    if printf '%s' "$out" | grep -q "build=${want_build}; publish=${want_publish}"; then
        ok "$desc"
    else
        bad "${desc}（期望 build=${want_build} publish=${want_publish}，实际: ${out}）"
    fi
}

# dry-run 的优先级必须高于所有触发分支，否则验证构建会误发正式 Release
expect_policy "dispatch + dry_run → 构建但不发布" true false \
    EVENT_NAME=workflow_dispatch VERSION_INPUT=0.1.1-rc.2 DRY_RUN=true
expect_policy "tag 推送 + dry_run → dry_run 压过 tag 发布" true false \
    EVENT_NAME=push REF_NAME=v0.1.1-rc.2 DRY_RUN=true
# 回归：未指定 dry_run 时原有发布行为不得被改变
expect_policy "dispatch + force_rebuild（无 dry_run）→ 正常发布" true true \
    EVENT_NAME=workflow_dispatch VERSION_INPUT=0.1.1-rc.2 FORCE_REBUILD=true
expect_policy "tag 推送（无 dry_run）→ 正常发布" true true \
    EVENT_NAME=push REF_NAME=v0.1.1-rc.2
rm -rf "${STUB}"

echo
echo "================================"
echo "结果: ${PASS} 通过, ${FAIL} 失败"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
