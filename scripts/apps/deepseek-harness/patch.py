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
                    code = code.replace('import fs from node:fs;\n', '')
                    code = code.replace('import fs from "node:fs";\n', '')
                    code = 'import fs from "node:fs";\n' + code

                    fnos_block = '''function fnosTargetHome() {
\ttry {
\t\tif (fs.existsSync("/vol1/@appshare/DeepSeekHarness")) return "/vol1/@appshare/DeepSeekHarness";
\t\tif (fs.existsSync("/vol1")) return "/vol1";
\t} catch (e) {}
\treturn homedir();
}
\t\tconst home = fnosTargetHome();
\t\t'''

                    if 'function fnosTargetHome()' in code:
                        f_pos = code.find('function fnosTargetHome()')
                        next_pos = code.find('if (path !== void 0', f_pos)
                        if next_pos != -1:
                            code = code[:f_pos] + fnos_block + code[next_pos:]
                            changed = True
                    elif 'const home = homedir();' in code:
                        code = code.replace('const home = homedir();', fnos_block)
                        changed = True

                if changed:
                    with open(p, 'w', encoding='utf-8') as fp:
                        fp.write(code)

    print("[✓] 全部补丁应用完成！")

if __name__ == '__main__':
    target_root = sys.argv[1] if len(sys.argv) > 1 else '.'
    apply_patches(target_root)
