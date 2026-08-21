import os
import re
import sys


PRESET_PROVIDER_LABEL = '一万AI分享'

def apply_patches(app_root):
    print(f"[*] 正在为 {app_root} 应用补丁...")
    modules_dir = os.path.join(app_root, 'node_modules', '@deepseek-ai')
    if not os.path.exists(modules_dir):
        print(f"[!] 找不到目标目录: {modules_dir}")
        return

    for root, dirs, files in os.walk(modules_dir):
        for f in files:
            if f.endswith('.js') or f.endswith('.mjs'):
                p = os.path.join(root, f)
                try:
                    with open(p, 'r', encoding='utf-8', errors='ignore') as fp:
                        code = fp.read()
                except Exception:
                    continue

                changed = False

                # 不改写依赖模块内的 crypto.randomUUID()。runner.js 会在 HTML 的
                # <head> 最前注入浏览器 Polyfill；对压缩后的依赖做全局文本替换会
                # 破坏 JavaScript 语法，也会影响 Node.js 侧本已可用的原生实现。

                # 1. 修复 403 CSRF/Origin 拦截
                if 'function isTrustedApiRequest(' in code:
                    code = code.replace('function isTrustedApiRequest(request, trustedHosts) {', 'function isTrustedApiRequest(request, trustedHosts) { return true;')
                    changed = True

                # 1b. 修复浏览器端 "settings are unavailable in this browser"
                # 根因：DSH 将 settings.describe 等 RPC 视为 loopback-only。经飞牛桌面
                # iframe（http://<NAS_IP>:3080）打开时 location.hostname 非 loopback，
                # 浏览器端 isLoopback=false → SettingsDescribeMirror persistence=memory
                # → 设置 mirror 永远拿不到视图 → 设置页报错。
                # 与 isTrustedApiRequest 同样思路：经本应用反代/控制页访问即视为可信直连。
                # 服务端本身无 loopback 校验（已验证），此改动不新增暴露面。
                if 'dsh-client-connection' in p and f == 'client.js':
                    before = code
                    code = code.replace(
                        'isLoopback: pageLocation === void 0 || isLoopbackHostname(pageLocation.hostname),',
                        'isLoopback: true, // fnOS fix: settings RPC via desktop iframe (trust proxy/control panel access as loopback)'
                    )
                    changed = changed or code != before

                # 2. 仅重命名预制的 deepseek-official 路由，不改动其内部 ID、模型目录
                # 或前端选择逻辑。这样用户在 Models 页面看到的是“一万AI分享”，同时
                # 仍可编辑该配置、添加多个模型，以及继续新增自己的提供商。
                if 'dsh-llm-deepseek' in p and f == 'index.js':
                    before = code
                    code = code.replace('name: "DeepSeek"', f'name: "{PRESET_PROVIDER_LABEL}"')
                    code = code.replace('displayName: "DeepSeek"', f'displayName: "{PRESET_PROVIDER_LABEL}"')
                    changed = changed or code != before

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

    print("[OK] 全部补丁应用完成！")

if __name__ == '__main__':
    target_root = sys.argv[1] if len(sys.argv) > 1 else '.'
    apply_patches(target_root)
