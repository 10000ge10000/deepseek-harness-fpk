import os
import sys

def apply_patches(app_root):
    safe_expr = '(((typeof crypto!=="undefined"&&crypto.randomUUID)?crypto.randomUUID():("10000000-1000-4000-8000-100000000000".replace(/[018]/g,function(c){return(c^(typeof crypto!=="undefined"&&crypto.getRandomValues?crypto.getRandomValues(new Uint8Array(1))[0]:Math.floor(Math.random()*256))&(15>>(c/4))).toString(16);}))))'

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
                
                # 清理之前残留的语法错误
                if 'import fs from node:fs;\n' in code:
                    code = code.replace('import fs from node:fs;\n', '')
                    changed = True
                if ':(10000000-1000-4000-8000-100000000000.replace' in code:
                    code = code.replace(':(10000000-1000-4000-8000-100000000000.replace', ':("10000000-1000-4000-8000-100000000000".replace')
                    changed = True

                # 1. 修复 randomUUID（局域网非安全上下文）
                if 'crypto.randomUUID()' in code:
                    code = code.replace('crypto.randomUUID()', safe_expr)
                    changed = True
                
                # 2. 修复 403 CSRF/Origin 拦截
                if 'function isTrustedApiRequest(' in code:
                    code = code.replace('function isTrustedApiRequest(request, trustedHosts) {', 'function isTrustedApiRequest(request, trustedHosts) { return true;')
                    changed = True
                    
                # 3. 定制 dsh-llm-deepseek 提供商与唯一模型
                if 'dsh-llm-deepseek' in p and f == 'index.js':
                    code = code.replace('displayName: "DeepSeek"', 'displayName: "一万AI分享"')
                    code = code.replace('name: "DeepSeek"', 'name: "一万AI分享"')
                    code = code.replace('name: "DeepSeek-V4-Flash"', 'name: "一万AI分享DSH专用模型"')
                    code = code.replace('id: "deepseek-v4-flash"', 'id: "一万AI分享DSH专用模型"')
                    code = code.replace('name: "DeepSeek-V4-Pro"', 'name: "一万AI分享DSH专用模型"')
                    code = code.replace('id: "deepseek-v4-pro"', 'id: "一万AI分享DSH专用模型"')
                    
                    code = code.replace('return (models ?? DEFAULT_MODELS).map', 'return DEFAULT_MODELS.map')
                    code = code.replace('return (models ?? DEFAULT_MODELS)', 'return DEFAULT_MODELS')
                    changed = True

                # 4. 定制 dsh-client-connection 中的模型与 fixture
                if 'dsh-client-connection' in p and f == 'client.js':
                    code = code.replace('name: "DeepSeek-V4-Flash"', 'name: "一万AI分享DSH专用模型"')
                    code = code.replace('id: "deepseek-v4-flash"', 'id: "一万AI分享DSH专用模型"')
                    code = code.replace('name: "DeepSeek-V4-Pro"', 'name: "一万AI分享DSH专用模型"')
                    code = code.replace('id: "deepseek-v4-pro"', 'id: "一万AI分享DSH专用模型"')
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

                # 5. 定制 dsh-client-ui-settings-models 卡片标题
                if 'dsh-client-ui-settings-models' in p and f == 'client.js':
                    if 'children: row.entry.displayName' in code:
                        code = code.replace('children: row.entry.displayName', 'children: (row.entry.provider === "deepseek-official" || row.entry.displayName === "DeepSeek") ? "一万AI分享" : row.entry.displayName')
                        changed = True

                # 6. 定制 dsh-client-ui-model-selection 下拉单模型
                if 'dsh-client-ui-model-selection' in p and f == 'client.js':
                    code = code.replace('state.groups.flatMap((group) => group.models.map((model)', 'state.groups.flatMap((group) => group.models.slice(0, 1).map((model)')
                    code = code.replace('group.models.map((model) => {', 'group.models.slice(0, 1).map((model) => {')
                    if 'children: group.name' in code:
                        code = code.replace('children: group.name', 'children: (group.id === "deepseek-official" || group.name === "DeepSeek") ? "一万AI分享" : group.name')
                    changed = True

                # 7. 定制 dsh-host-directory-picker-browse 飞牛共享目录
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
