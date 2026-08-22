import os
import re
import sys


PRESET_PROVIDER_LABEL = '一万AI分享'
PRESET_MODEL_LABEL = '一万AI分享DSH专用模型'

# 上游 dsh-llm-deepseek 的内置模型目录（tab 缩进，字节级精确匹配）。
# 上游给三条内置模型且 contextWindow=1e6（1M）：多轮会话请求体按 1M 滚雪球
# 是首字耗时飙升的根因；且 settings.yaml 的 defaultContextWindow 只对目录
# 之外的模型兜底（configured?.contextWindow ?? defaultContextWindow），对
# 内置条目不生效，必须改插件常量本身。
DEFAULT_MODELS_UPSTREAM = (
    'const DEFAULT_MODELS = [\n'
    '\t{\n'
    '\t\tid: "deepseek-v4-flash",\n'
    '\t\tname: "DeepSeek-V4-Flash",\n'
    '\t\tcontextWindow: DEFAULT_CONTEXT_WINDOW\n'
    '\t},\n'
    '\t{\n'
    '\t\tid: "deepseek-v4-pro",\n'
    '\t\tname: "DeepSeek-V4-Pro",\n'
    '\t\tcontextWindow: DEFAULT_CONTEXT_WINDOW\n'
    '\t},\n'
    '\t{\n'
    '\t\tid: "deepseek-v4-flash-vision-exp",\n'
    '\t\tname: "DeepSeek-V4-Flash-Vision-Exp",\n'
    '\t\tcontextWindow: DEFAULT_CONTEXT_WINDOW,\n'
    '\t\tinputModalities: ["text", "image"],\n'
    '\t\timagePixelBudget: DEFAULT_REQUEST_IMAGE_PIXEL_BUDGET,\n'
    '\t\timageMaxBytes: DEFAULT_REQUEST_IMAGE_MAX_BYTES\n'
    '\t}\n'
    '];'
)

# 收敛后的目录：仅保留默认模型（id 不变，API 请求与公益站完全兼容），
# 显示名换品牌名；上下文由 DEFAULT_CONTEXT_WINDOW=2e5 统一锁定为 200k。
DEFAULT_MODELS_BRANDED = (
    'const DEFAULT_MODELS = [\n'
    '\t{\n'
    '\t\tid: "deepseek-v4-flash",\n'
    f'\t\tname: "{PRESET_MODEL_LABEL}",\n'
    '\t\tcontextWindow: DEFAULT_CONTEXT_WINDOW\n'
    '\t}\n'
    '];'
)

def apply_patches(app_root):
    print(f"[*] 正在为 {app_root} 应用补丁...")
    modules_dir = os.path.join(app_root, 'node_modules', '@deepseek-ai')
    if not os.path.exists(modules_dir):
        print(f"[!] 找不到目标目录: {modules_dir}")
        return

    structural_failures = []

    for root, dirs, files in os.walk(modules_dir):
        for f in files:
            if f.endswith('.js') or f.endswith('.mjs'):
                p = os.path.join(root, f)
                try:
                    with open(p, 'r', encoding='utf-8', errors='ignore') as fp:
                        code = fp.read()
                except Exception as e:
                    # 静默跳过会导致补丁漏打且无迹可查，必须留下日志
                    print(f"[!] 跳过无法读取的文件 {p}: {e}")
                    continue

                changed = False

                # 不改写依赖模块内的 crypto.randomUUID()。runner.js 会在 HTML 的
                # <head> 最前注入浏览器 Polyfill；对压缩后的依赖做全局文本替换会
                # 破坏 JavaScript 语法，也会影响 Node.js 侧本已可用的原生实现。

                # 1. 修复 403 CSRF/Origin 拦截
                if 'function isTrustedApiRequest(' in code:
                    code = code.replace('function isTrustedApiRequest(request, trustedHosts) {', 'function isTrustedApiRequest(request, trustedHosts) { return true;')
                    changed = True

                # 1b. 修复浏览器端 "settings are unavailable in this browser" (Issue #2)
                # 根因：DSH 将 settings.describe 等 RPC 视为 loopback-only。经飞牛桌面
                # iframe（http://<NAS_IP>:3080）或局域网打开时 location.hostname 非 loopback，
                # 浏览器端 isLoopback=false → SettingsDescribeMirror persistence=memory
                # → 设置 mirror 永远拿不到视图 → 设置页报错。
                # 与 isTrustedApiRequest 同样思路：经本应用反代/控制页访问即视为可信直连。
                # 服务端本身无 loopback 校验（已验证），此改动不新增暴露面。
                if 'function isLoopbackHostname(' in code and 'function isLoopbackHostname(hostname) { return true;' not in code:
                    code = code.replace('function isLoopbackHostname(hostname) {', 'function isLoopbackHostname(hostname) { return true;')
                    changed = True

                if 'dsh-client-connection' in p and f == 'client.js':
                    before = code
                    code = code.replace(
                        'isLoopback: pageLocation === void 0 || isLoopbackHostname(pageLocation.hostname),',
                        'isLoopback: true, // fnOS fix (Issue #2): trust proxy/control panel access as loopback'
                    )
                    changed = changed or code != before

                # 2. 预制 deepseek-official 路由品牌化：提供商显示名改“一万AI分享”，
                # 内置模型目录收敛为单一“一万AI分享DSH专用模型”并锁定 200k 上下文。
                # 提供商内部 ID 不动，用户仍可在 Models 页面编辑配置、新增自己的
                # 提供商和模型。
                if 'dsh-llm-deepseek' in p and f == 'index.js':
                    before = code
                    code = code.replace('name: "DeepSeek"', f'name: "{PRESET_PROVIDER_LABEL}"')
                    code = code.replace('displayName: "DeepSeek"', f'displayName: "{PRESET_PROVIDER_LABEL}"')
                    code = code.replace('const DEFAULT_CONTEXT_WINDOW = 1e6;', 'const DEFAULT_CONTEXT_WINDOW = 2e5;')
                    code = code.replace(DEFAULT_MODELS_UPSTREAM, DEFAULT_MODELS_BRANDED)
                    changed = changed or code != before
                    # 目录收敛的结构性复核：整块替换若因上游改版落空，残留的
                    # v4-pro / vision-exp 条目说明匹配已漂移，必须显式失败，
                    # 不能带着 1M 上下文的多模型目录发布出去。
                    if 'id: "deepseek-v4-pro",' in code or 'id: "deepseek-v4-flash-vision-exp",' in code:
                        structural_failures.append('内置模型目录仍含 v4-pro / vision-exp 条目（DEFAULT_MODELS 匹配漂移，需人工更新 patch.py）')

                if 'dsh-client-connection' in p and f == 'client.js':
                    code, group_replacements = re.subn(
                        r'(id:\s*"deepseek-official",\s*name:\s*)"DeepSeek"',
                        rf'\1"{PRESET_PROVIDER_LABEL}"',
                        code,
                    )
                    code, provider_replacements = re.subn(
                        r'(provider:\s*"deepseek-official",\s*displayName:\s*)"DeepSeek"',
                        rf'\1"{PRESET_PROVIDER_LABEL}"',
                        code,
                    )
                    changed = changed or group_replacements > 0 or provider_replacements > 0

                # 3. 定制 dsh-host-directory-picker-browse 飞牛共享目录
                if 'dsh-host-directory-picker-browse' in p and f == 'index.js':
                    # 上游 rc.8 起生成物以 `import fs from "node:fs";` 开头，
                    # 两种引号形式都覆盖；若该行不存在则跳过（保持原文件）。
                    if 'import fs from "node:fs";' in code:
                        code = code.replace('import fs from "node:fs";\n', '')
                        code = 'import fs from "node:fs";\n' + code
                    elif 'import fs from node:fs;\n' in code:
                        code = code.replace('import fs from node:fs;\n', 'import fs from "node:fs";\n')
                        changed = True

                    fnos_block = '''function fnosTargetHome() {
\ttry {
\t\tif (fs.existsSync("/vol1/@appshare/DeepSeekHarness")) return "/vol1/@appshare/DeepSeekHarness";
\t\tif (fs.existsSync("/vol1")) return "/vol1";
\t} catch (e) {}
\treturn homedir();
}
\t\tconst home = fnosTargetHome();
\t\t'''

                    # 先把文件还原到上游形态，再重新注入，保证幂等（重复执行不叠加）：
                    # 1) 摘掉所有 fnosTargetHome 函数定义；2) 若残留 `const home = fnosTargetHome();`
                    # 把它还原为 `const home = homedir();`；3) 只在 `const home = homedir();`
                    # 存在时替换成 fnos_block。若上游形态被破坏（一个 home 赋值都没有），
                    # 放弃修改，保持原文件（build.sh 的 node --check 会兜底拦截）。
                    target = 'const home = homedir();'
                    if 'function fnosTargetHome()' in code:
                        code = re.sub(r'function fnosTargetHome\(\) \{.*?\n\}\n', '', code, flags=re.S)
                    if 'const home = fnosTargetHome();' in code:
                        code = code.replace('const home = fnosTargetHome();', target)
                    if target in code:
                        # 只注入一次；残留的多余赋值（旧注入还原后与原文件叠加）一律清除
                        code = code.replace(target, fnos_block, 1)
                        code = code.replace(target, '')
                        changed = True

                if changed:
                    with open(p, 'w', encoding='utf-8') as fp:
                        fp.write(code)

    # 关键补丁落点验证：上游改版可能让文本匹配静默落空，语法校验无法发现
    # 『补丁没打上』。这里按补丁后的标志性代码复核，缺失即失败，防止把
    # 局域网不可用的包发布出去（缺失的实机症状是 403 与 settings are
    # unavailable）。以『标志存在』而非『本次替换发生』计数，重复执行
    # （幂等）不会误报。
    CRITICAL_MARKERS = {
        'CSRF 信任放行': 'isTrustedApiRequest(request, trustedHosts) { return true;',
        'loopback 信任修复 (Issue #2)': 'isLoopbackHostname(hostname) { return true;',
        '浏览器端 isLoopback 直连': 'isLoopback: true, // fnOS fix',
        '上下文窗口锁定 200k': 'const DEFAULT_CONTEXT_WINDOW = 2e5;',
        '单一品牌模型目录': f'name: "{PRESET_MODEL_LABEL}"',
    }
    OPTIONAL_MARKERS = {
        '提供商改名（外观性，缺失仅告警）': 'name: "一万AI分享"',
    }

    def count_marker(marker):
        hits = 0
        for root, dirs, files in os.walk(modules_dir):
            for f in files:
                if f.endswith(('.js', '.mjs')):
                    try:
                        with open(os.path.join(root, f), 'r', encoding='utf-8', errors='ignore') as fp:
                            if marker in fp.read():
                                hits += 1
                    except Exception:
                        continue
        return hits

    failed = False
    for label, marker in CRITICAL_MARKERS.items():
        hits = count_marker(marker)
        if hits == 0:
            print(f"[FAIL] 关键补丁未命中: {label}（上游代码可能已变更，需人工更新 patch.py）")
            failed = True
        else:
            print(f"[OK] 关键补丁验证通过: {label}（{hits} 处）")
    for label, marker in OPTIONAL_MARKERS.items():
        hits = count_marker(marker)
        level = 'OK' if hits > 0 else 'WARN'
        print(f"[{level}] 可选补丁 {label}: {hits} 处")
    for msg in structural_failures:
        print(f"[FAIL] {msg}")
        failed = True

    if failed:
        print("[FAIL] 存在未命中的关键补丁，拒绝继续打包")
        sys.exit(1)
    print("[OK] 全部补丁应用完成！")

if __name__ == '__main__':
    target_root = sys.argv[1] if len(sys.argv) > 1 else '.'
    apply_patches(target_root)
