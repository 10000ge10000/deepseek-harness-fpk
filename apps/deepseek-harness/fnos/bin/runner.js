/**
 * DeepSeek Harness - fnOS 统一运行器 (Runner)
 * 1. 负责启动上游 dsh web (127.0.0.1:3081)
 * 2. 负责启动局域网透明反向代理 (0.0.0.0:3080 -> 127.0.0.1:3081)
 * 3. 自动注入 crypto.randomUUID Polyfill (解决非安全上下文局域网浏览器报错)
 * 4. 精确进程生命周期管理，响应 SIGTERM/SIGINT 秒级退出
 */

const { spawn } = require('child_process');
const fs = require('fs');
const http = require('http');
const net = require('net');
const path = require('path');

const APP_DIR = process.env.TRIM_APPDEST || path.resolve(__dirname, '..');
const VAR_DIR = process.env.TRIM_PKGVAR || path.join(APP_DIR, 'data');
const NODE_BIN = path.join(APP_DIR, 'bin', 'node');
const DSH_BIN = path.join(APP_DIR, 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js');

const PROXY_PORT = parseInt(process.env.PORT || '3080', 10);
const DSH_PORT = 3081;
const DEFAULT_BASE_URL = 'https://api.910501.xyz/v1';
const LEGACY_MODEL = '一万AI分享DSH专用模型';

// DSH 的可编辑设置、凭据和插件 profile 都由 HOME 下的 .dsh 管理。
// 先确定飞牛工作区，才能在启动前安全迁移旧配置。
let WORKSPACE_DIR = VAR_DIR;
if (fs.existsSync('/vol1/@appshare/DeepSeekHarness')) {
    WORKSPACE_DIR = '/vol1/@appshare/DeepSeekHarness';
} else if (fs.existsSync('/vol1')) {
    WORKSPACE_DIR = '/vol1';
}

// 读取向导配置变量 (wizard_variables)
const dshEnv = { ...process.env };
const wizardVarsFile = path.join(VAR_DIR, 'wizard_variables');
if (fs.existsSync(wizardVarsFile)) {
    try {
        const content = fs.readFileSync(wizardVarsFile, 'utf-8');
        const lines = content.split('\n');
        for (const line of lines) {
            const trimmed = line.trim();
            if (!trimmed || trimmed.startsWith('#')) continue;
            const eqIdx = trimmed.indexOf('=');
            if (eqIdx !== -1) {
                const key = trimmed.slice(0, eqIdx).trim();
                let val = trimmed.slice(eqIdx + 1).trim();
                if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
                    val = val.slice(1, -1);
                }
                dshEnv[key] = val;
            }
        }
    } catch (e) {
        console.warn('[Runner] 读取向导变量失败:', e);
    }
}

// 向导 Key 仅在首次启动时写入 DSH 的可编辑凭据存储。
// 不映射为 DEEPSEEK_API_KEY：该环境变量优先级最高，DSH 会按设计把它
// 标成只读，用户便无法在 Models 页面替换为自己的 DeepSeek API Key。
const wizardApiKey = dshEnv.wizard_api_key || dshEnv.api_key || dshEnv.DEEPSEEK_API_KEY || dshEnv.OPENAI_API_KEY || '';
delete dshEnv.wizard_api_key;
delete dshEnv.api_key;
delete dshEnv.DEEPSEEK_API_KEY;
delete dshEnv.OPENAI_API_KEY;
delete dshEnv.DSH_DEFAULT_MODEL;
delete dshEnv.DSH_MODEL;
const customReasoning = 'high';

// 端点只作为未配置 Models 页时的默认值。用户在 Models 页保存自己的 base URL
// 后会立即优先使用设置层，无需重启。
if (!dshEnv.DEEPSEEK_BASE_URL) {
    dshEnv.DEEPSEEK_BASE_URL = DEFAULT_BASE_URL;
}

function appendEditableCredential(apiKey) {
    if (!apiKey) return false;
    const credentialFile = path.join(WORKSPACE_DIR, '.dsh', '.credentials.yaml');
    try {
        let content = '';
        if (fs.existsSync(credentialFile)) {
            content = fs.readFileSync(credentialFile, 'utf-8');
            // 早期版本会在可共享的工作区中留下权限过宽的凭据文件。新版 DSH
            // 会拒绝启动，因此即使 Key 已存在也必须在每次启动前收紧权限。
            fs.chmodSync(credentialFile, 0o600);
            if (/^\s*DEEPSEEK_API_KEY\s*:/m.test(content)) return false;
        } else {
            fs.mkdirSync(path.dirname(credentialFile), { recursive: true, mode: 0o700 });
        }
        const separator = content.length === 0 || content.endsWith('\n') ? '' : '\n';
        fs.writeFileSync(credentialFile, `${content}${separator}DEEPSEEK_API_KEY: ${JSON.stringify(apiKey)}\n`, {
            encoding: 'utf-8',
            mode: 0o600
        });
        fs.chmodSync(credentialFile, 0o600);
        return true;
    } catch (error) {
        console.warn('[Runner] 初始化可编辑 API 凭据失败:', error.message);
        return false;
    }
}

function migrateLegacyDefaultModel() {
    const settingsFile = path.join(WORKSPACE_DIR, '.dsh', 'settings.yaml');
    if (!fs.existsSync(settingsFile)) return false;
    try {
        const source = fs.readFileSync(settingsFile, 'utf-8');
        const legacyModel = /^(\s*model:\s*)(?:"一万AI分享DSH专用模型"|'一万AI分享DSH专用模型'|一万AI分享DSH专用模型)(\s*(?:#.*)?)$/m;
        if (!legacyModel.test(source)) return false;
        fs.writeFileSync(settingsFile, source.replace(legacyModel, '$1deepseek-v4-flash$2'), 'utf-8');
        return true;
    } catch (error) {
        console.warn('[Runner] 迁移旧默认模型失败:', error.message);
        return false;
    }
}

function ensurePublicSiteContextLimit() {
    const settingsFile = path.join(WORKSPACE_DIR, '.dsh', 'settings.yaml');
    try {
        if (!fs.existsSync(settingsFile)) return false;
        let content = fs.readFileSync(settingsFile, 'utf-8');
        if (!content.includes('defaultContextWindow:') && !content.includes('llm-deepseek:')) {
            const extraConfig = `\nllm-deepseek:\n  defaultContextWindow: 200000\n  models:\n    - id: deepseek-v4-flash\n      name: DeepSeek-V4-Flash\n      contextWindow: 200000\n    - id: deepseek-v4-pro\n      name: DeepSeek-V4-Pro\n      contextWindow: 200000\n`;
            fs.appendFileSync(settingsFile, extraConfig, 'utf-8');
            return true;
        }
    } catch (e) {
        console.warn('[Runner] 初始化公益站点模型上下文限制失败:', e.message);
    }
    return false;
}

// 修复 "duplicate catalog model" 导致的 boot 失败（症状：UI 里所有会话消失）。
// dsh-llm-deepseek 的内置 catalog 已含 deepseek-v4-flash / deepseek-v4-pro，
// 若 settings.yaml 的 llm-deepseek.models 也写入了同名 id，启动时模型条目重复，
// 插件树加载失败 -> dsh 直接退出 -> 会话列表为空。这里把用户配置中与内置
// catalog 重复的条目剔除，保留新增的自定义模型。
function dedupeCatalogModels() {
    const settingsFile = path.join(WORKSPACE_DIR, '.dsh', 'settings.yaml');
    try {
        if (!fs.existsSync(settingsFile)) return false;
        let content = fs.readFileSync(settingsFile, 'utf-8');
        const builtinIds = ['deepseek-v4-flash', 'deepseek-v4-pro'];
        const lines = content.split('\n');
        let out = [];
        let inModels = false;
        let changed = false;
        let skipTillBlank = false; // 跳过当前被剔除条目的后续属性行，直到下一个 '- id:' 或顶层键
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i];
            if (/^\s{0,2}llm-deepseek:\s*$/.test(line)) {
                out.push(line);
                inModels = false;
                skipTillBlank = false;
                continue;
            }
            const isTopKey = /^\s{0,2}[a-zA-Z0-9_-]+:\s*$/.test(line);
            if (isTopKey) {
                inModels = /^\s{0,2}models:\s*$/.test(line);
                skipTillBlank = false;
                out.push(line);
                continue;
            }
            if (/^\s+-\s+id:\s*['"]?([a-zA-Z0-9_.-]+)['"]?\s*$/.test(line)) {
                const id = line.match(/^\s+-\s+id:\s*['"]?([a-zA-Z0-9_.-]+)['"]?\s*$/)[1];
                if (inModels && builtinIds.includes(id)) {
                    changed = true;
                    skipTillBlank = true;
                    continue;
                }
                skipTillBlank = false;
                out.push(line);
                continue;
            }
            if (skipTillBlank) continue; // 跳过被剔除条目的 name/contextWindow 等属性行
            out.push(line);
        }
        if (changed) {
            // 若剔除后 models 列表为空，直接删除整个 models 键（空列表会导致
            // dsh 无模型可选；删除后 dsh 回落到内置目录）。
            const cleaned = out.join('\n').replace(/\n?\s{2}models:\s*(?=\n[a-zA-Z0-9_-]+:|\s*$)/, '');
            fs.writeFileSync(settingsFile, cleaned, 'utf-8');
            return true;
        }
    } catch (e) {
        console.warn('[Runner] 去重内置模型配置失败:', e.message);
    }
    return false;
}

const seededCredential = appendEditableCredential(wizardApiKey);
const migratedModel = migrateLegacyDefaultModel();
const contextLimitInjected = ensurePublicSiteContextLimit();
const catalogDeduped = dedupeCatalogModels();

// 强力 Polyfill 脚本：全面覆盖 window, self, globalThis, Crypto.prototype 以及 AbortSignal.any / AbortSignal.timeout
const POLYFILL_SCRIPT = `<script>
(function() {
  function createUUID() {
    if (typeof crypto !== 'undefined' && crypto.getRandomValues) {
      return ([1e7]+-1e3+-4e3+-8e3+-1e11).replace(/[018]/g, function(c) {
        return (c ^ (crypto.getRandomValues(new Uint8Array(1))[0] & (15 >> (c / 4)))).toString(16);
      });
    }
    return '10000000-1000-4000-8000-100000000000'.replace(/[018]/g, function(c) {
      return (c ^ (Math.floor(Math.random() * 256)) & (15 >> (c / 4))).toString(16);
    });
  }

  try {
    var g = typeof globalThis !== 'undefined' ? globalThis : typeof window !== 'undefined' ? window : typeof self !== 'undefined' ? self : this;
    if (typeof window !== 'undefined') {
      window.__DSH_LOCAL_APP__ = true;
    }
    
    // 1. AbortSignal.any Polyfill (解决华为平板/安卓老旧浏览器/微信WebView "AbortSignal.any is not a function")
    if (typeof g.AbortSignal !== 'undefined' && !g.AbortSignal.any) {
      g.AbortSignal.any = function(signals) {
        var controller = new AbortController();
        if (!signals || !signals.length) return controller.signal;
        for (var i = 0; i < signals.length; i++) {
          var s = signals[i];
          if (!s) continue;
          if (s.aborted) {
            controller.abort(s.reason);
            return controller.signal;
          }
          s.addEventListener('abort', function() {
            controller.abort(this.reason);
          }, { once: true });
        }
        return controller.signal;
      };
    }

    // 2. AbortSignal.timeout Polyfill
    if (typeof g.AbortSignal !== 'undefined' && !g.AbortSignal.timeout) {
      g.AbortSignal.timeout = function(ms) {
        var controller = new AbortController();
        setTimeout(function() {
          var err = new Error('The operation timed out');
          err.name = 'TimeoutError';
          controller.abort(err);
        }, ms);
        return controller.signal;
      };
    }

    // 3. crypto.randomUUID Polyfill (解决局域网非安全上下文)
    if (!g.crypto) {
      try { g.crypto = {}; } catch(e){}
    }
    if (g.crypto) {
      try {
        if (!g.crypto.randomUUID) {
          Object.defineProperty(g.crypto, 'randomUUID', {
            value: createUUID,
            writable: true,
            configurable: true,
            enumerable: true
          });
        }
      } catch (e) {
        g.crypto.randomUUID = createUUID;
      }
    }
    if (typeof Crypto !== 'undefined' && Crypto.prototype && !Crypto.prototype.randomUUID) {
      try {
        Object.defineProperty(Crypto.prototype, 'randomUUID', {
          value: createUUID,
          writable: true,
          configurable: true,
          enumerable: true
        });
      } catch (e) {}
    }

    // 4. Promise.withResolvers Polyfill
    if (typeof Promise !== 'undefined' && !Promise.withResolvers) {
      Promise.withResolvers = function() {
        var resolve, reject;
        var promise = new Promise(function(res, rej) {
          resolve = res;
          reject = rej;
        });
        return { promise: promise, resolve: resolve, reject: reject };
      };
    }
  } catch (e) {
    console.warn('[DSH Polyfill] 初始化异常:', e);
  }
})();
</script>`;

console.log(`[Runner] 正在启动 DeepSeek Harness 后台服务 (127.0.0.1:${DSH_PORT})...`);
console.log(`[Runner] 默认 API 端点: ${dshEnv.DEEPSEEK_BASE_URL}，Models 页面可覆盖；默认推理强度: ${customReasoning}`);
if (seededCredential) console.log('[Runner] 已将向导 API Key 初始化为可编辑凭据');
if (migratedModel) console.log('[Runner] 已迁移旧的一万AI分享默认模型配置');
if (contextLimitInjected) console.log('[Runner] 已为内置公益站点模型配置 200k 上下文上限保护 (支持自动静默压缩)');
if (catalogDeduped) console.log('[Runner] 已剔除 llm-deepseek 配置中与内置目录重复的模型条目');

const dshProcess = spawn(NODE_BIN, [DSH_BIN, 'web', '--host', '127.0.0.1', '--port', String(DSH_PORT)], {
    cwd: WORKSPACE_DIR,
    env: {
        ...dshEnv,
        PATH: `${path.join(APP_DIR, 'bin')}:${process.env.PATH}`,
        HOME: WORKSPACE_DIR
    },
    stdio: 'inherit'
});

dshProcess.on('exit', (code, signal) => {
    console.log(`[Runner] dsh 进程退出，退出码: ${code}, 信号: ${signal}`);
    process.exit(code || 0);
});

// 创建透明反代服务 (0.0.0.0:3080)
const proxyServer = http.createServer((clientReq, clientRes) => {
    const headers = {
        ...clientReq.headers,
        'x-forwarded-for': clientReq.socket.remoteAddress,
        'x-forwarded-proto': 'http',
        'x-forwarded-host': clientReq.headers.host || `0.0.0.0:${PROXY_PORT}`,
        host: `127.0.0.1:${DSH_PORT}`
    };

    // 核心修复：对齐 Origin 与 Referer 避免触发 dsh 上游后端的 CSRF/Host 403 拦截
    if (clientReq.headers.origin) {
        headers.origin = `http://127.0.0.1:${DSH_PORT}`;
    }
    if (clientReq.headers.referer) {
        headers.referer = `http://127.0.0.1:${DSH_PORT}/`;
    }
    if (headers['sec-fetch-site'] === 'cross-site') {
        headers['sec-fetch-site'] = 'same-origin';
    }

    const isHtmlPath = clientReq.url === '/' || clientReq.url.endsWith('.html') || !clientReq.url.includes('.');
    if (isHtmlPath) {
        delete headers['accept-encoding'];
    }

    const options = {
        hostname: '127.0.0.1',
        port: DSH_PORT,
        path: clientReq.url,
        method: clientReq.method,
        headers
    };

    const proxyReq = http.request(options, (proxyRes) => {
        const contentType = proxyRes.headers['content-type'] || '';
        const isHtml = contentType.includes('text/html');

        if (isHtml) {
            let chunks = [];
            proxyRes.on('data', chunk => chunks.push(chunk));
            proxyRes.on('end', () => {
                let body = Buffer.concat(chunks).toString('utf-8');
                if (body.includes('<head>')) {
                    body = body.replace('<head>', `<head>${POLYFILL_SCRIPT}`);
                } else if (body.includes('<!DOCTYPE html>')) {
                    body = body.replace('<!DOCTYPE html>', `<!DOCTYPE html>${POLYFILL_SCRIPT}`);
                } else {
                    body = POLYFILL_SCRIPT + body;
                }

                const resHeaders = { ...proxyRes.headers };
                delete resHeaders['content-length'];
                resHeaders['content-length'] = Buffer.byteLength(body, 'utf-8');
                // 禁止浏览器缓存，确保每次获取最新代码
                resHeaders['cache-control'] = 'no-store, no-cache, must-revalidate';
                resHeaders['pragma'] = 'no-cache';

                clientRes.writeHead(proxyRes.statusCode, resHeaders);
                clientRes.end(body);
            });
        } else {
            // 对 JS/CSS 等静态资源也添加 no-cache 头
            const resHeaders = { ...proxyRes.headers };
            resHeaders['cache-control'] = 'no-store, no-cache, must-revalidate';
            resHeaders['pragma'] = 'no-cache';
            clientRes.writeHead(proxyRes.statusCode, resHeaders);
            proxyRes.pipe(clientRes, { end: true });
        }
    });

    proxyReq.on('error', (err) => {
        if (!clientRes.headersSent) {
            clientRes.writeHead(502, { 'Content-Type': 'text/html; charset=utf-8' });
            clientRes.end('<h3>DeepSeek Harness 正在启动中，请稍候刷新...</h3>');
        }
    });

    clientReq.pipe(proxyReq, { end: true });
});

// 支持 WebSocket / HTTP Upgrade
proxyServer.on('upgrade', (req, socket, head) => {
    const headers = { ...req.headers };
    headers.host = `127.0.0.1:${DSH_PORT}`;
    if (headers.origin) {
        headers.origin = `http://127.0.0.1:${DSH_PORT}`;
    }
    if (headers['sec-fetch-site'] === 'cross-site') {
        headers['sec-fetch-site'] = 'same-origin';
    }

    const proxySocket = net.connect(DSH_PORT, '127.0.0.1', () => {
        proxySocket.write(
            `${req.method} ${req.url} HTTP/${req.httpVersion}\r\n` +
            Object.entries(headers)
                .map(([k, v]) => `${k}: ${v}`)
                .join('\r\n') +
            '\r\n\r\n'
        );
        if (head && head.length) proxySocket.write(head);
        socket.pipe(proxySocket);
        proxySocket.pipe(socket);
    });

    proxySocket.on('error', () => socket.destroy());
    socket.on('error', () => proxySocket.destroy());
});

proxyServer.listen(PROXY_PORT, '0.0.0.0', () => {
    console.log(`[Runner] 透明代理已启动: http://0.0.0.0:${PROXY_PORT} -> http://127.0.0.1:${DSH_PORT}`);
});

// 优雅且极速的退出处理
function shutdown() {
    console.log('[Runner] 收到停止信号，正在立即终止服务...');
    try {
        if (dshProcess && !dshProcess.killed) {
            dshProcess.kill('SIGKILL');
        }
    } catch (e) {}
    try {
        proxyServer.close();
    } catch (e) {}
    process.exit(0);
}

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
process.on('SIGHUP', shutdown);
