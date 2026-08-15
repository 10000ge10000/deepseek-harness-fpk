import os
import sys

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
                    
                # 2. 定制 dsh-llm-deepseek 提供商与唯一模型
                if 'dsh-llm-deepseek' in p and f == 'index.js':
                    code = code.replace('displayName: "DeepSeek"', 'displayName: "一万AI分享"')
                    code = code.replace('name: "DeepSeek"', 'name: "一万AI分享"')
                    code = code.replace('name: "DeepSeek-V4-Flash"', 'name: "一万AI分享DSH专用模型"')
                    code = code.replace('id: "deepseek-v4-flash"', 'id: "一万AI分享DSH专用模型"')
                    
                    # 只暴露第一个默认模型。此前将 Flash 与 Pro 同时替换成同一 ID，
                    # 会在 DSH 插件加载期触发 duplicate catalog model 并使进程退出。
                    code = code.replace('return (models ?? DEFAULT_MODELS).map', 'return DEFAULT_MODELS.slice(0, 1).map')
                    code = code.replace('return (models ?? DEFAULT_MODELS)', 'return DEFAULT_MODELS.slice(0, 1)')
                    changed = True

                # 3. 定制 dsh-client-connection 中的模型与 fixture
                if 'dsh-client-connection' in p and f == 'client.js':
                    code = code.replace('name: "DeepSeek-V4-Flash"', 'name: "一万AI分享DSH专用模型"')
                    code = code.replace('id: "deepseek-v4-flash"', 'id: "一万AI分享DSH专用模型"')
                    f_start = code.find('function fixtureModelGroups() {')
                    if f_start != -1:
                        f_end = code.find('function sid(', f_start)
                        if f_end != -1:
                            single_fixture = '''function fixtureModelGroups() {
\t\t\treturn [{
\t\t\t\tid: "deepseek-official",
\t\t\t\tname: "一万AI分享",
\t\t\t\tmodels: [{
\t\t\t\t\tid: "一万AI分享DSH专用模型",
\t\t\t\t\tname: "一万AI分享DSH专用模型",
\t\t\t\t\treasoning: DEEPSEEK_REASONING
\t\t\t\t}]
\t\t\t}];
\t\t}\n\t\t'''
                            code = code[:f_start] + single_fixture + code[f_end:]
                    changed = True

                # 4. 定制 dsh-client-ui-settings-models 卡片标题
                if 'dsh-client-ui-settings-models' in p and f == 'client.js':
                    if 'children: row.entry.displayName' in code:
                        code = code.replace('children: row.entry.displayName', 'children: (row.entry.provider === "deepseek-official" || row.entry.displayName === "DeepSeek") ? "一万AI分享" : row.entry.displayName')
                        changed = True

                # 5. 定制 dsh-client-ui-model-selection 下拉单模型
                if 'dsh-client-ui-model-selection' in p and f == 'client.js':
                    code = code.replace('state.groups.flatMap((group) => group.models.map((model)', 'state.groups.flatMap((group) => group.models.slice(0, 1).map((model)')
                    code = code.replace('group.models.map((model) => {', 'group.models.slice(0, 1).map((model) => {')
                    if 'children: group.name' in code:
                        code = code.replace('children: group.name', 'children: (group.id === "deepseek-official" || group.name === "DeepSeek") ? "一万AI分享" : group.name')
                    changed = True

                # 6. 定制 dsh-host-directory-picker-browse 飞牛共享目录
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
