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
    if GITHUB_REPOSITORY=someone/fork-test "$PY_BIN" scripts/ci/generate-appstore.py \
        --version 1.2.3 --tag v1.2.3 \
        --x86-fpk dsh_1.2.3_x86.fpk --arm-fpk dsh_1.2.3_arm.fpk \
        --out-dir "${OUTDIR}" >/dev/null 2>&1; then
        ok "脚本执行成功"
        "$PY_BIN" - "$OUTDIR" <<'PYEOF' 2>/dev/null
import json, sys, os
out = sys.argv[1]
data = json.load(open(os.path.join(out, 'appstore.json'), encoding='utf-8'))
assert len(data['apps']) == 2, 'apps 数量'
x86 = [a for a in data['apps'] if a['platform'] == 'x86'][0]
assert x86['download_url'].endswith('/dsh_1.2.3_x86.fpk'), 'x86 下载链接'
assert 'someone/fork-test' in x86['download_url'], '仓库 slug 来自 GITHUB_REPOSITORY'
assert 'someone/fork-test' in x86['icon'], 'icon 链接同样参数化'
html = open(os.path.join(out, 'index.html'), encoding='utf-8').read()
assert 'dsh_1.2.3_arm.fpk' in html, 'HTML 含 ARM 下载文件名'
assert '1.2.3' in html, 'HTML 含版本号'
PYEOF
        check $? "JSON/HTML 内容与 fork 参数化正确"
    else
        bad "脚本执行失败"
    fi
    rm -rf "${OUTDIR}"
else
    echo "  - 跳过：python 不可用"
fi

echo "== 8. build-fpk.sh 最小冒烟（假 app.tgz 组装结构）=="
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

echo
echo "================================"
echo "结果: ${PASS} 通过, ${FAIL} 失败"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
