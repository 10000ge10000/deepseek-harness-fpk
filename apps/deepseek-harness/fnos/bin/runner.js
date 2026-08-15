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

// 自动注入「一万AI分享」定制端点与模型配置
const customBaseUrl = 'https://api.910501.xyz/v1';
const customApiKey = dshEnv.wizard_api_key || dshEnv.api_key || '';
const customModel = '一万AI分享DSH专用模型';
const customReasoning = 'xhigh';

dshEnv.DEEPSEEK_BASE_URL = customBaseUrl;
dshEnv.OPENAI_BASE_URL = customBaseUrl;
if (customApiKey) {
    dshEnv.DEEPSEEK_API_KEY = customApiKey;
    dshEnv.OPENAI_API_KEY = customApiKey;
}
dshEnv.DSH_DEFAULT_MODEL = customModel;
dshEnv.DSH_MODEL = customModel;
dshEnv.DSH_REASONING_EFFORT = customReasoning;

// 强力 Polyfill 脚本：全面覆盖 window, self, globalThis, Crypto.prototype
const POLYFILL_SCRIPT = `<script>
(function() {
  function createUUID() {
    if (typeof crypto !== 'undefined' && crypto.getRandomValues) {
      return ([1e7]+-1e3+-4e3+-8e3+-1e11).replace(/[018]/g, function(c) {
        return (c ^ (crypto.getRandomValues(new Uint8Array(1))[0] & (15 >> (c / 4)))).toString(16);
      });
    }
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
      var r = Math.random() * 16 | 0, v = c === 'x' ? r : (r & 0x3 | 0x8);
      return v.toString(16);
    });
  }

  try {
    var g = typeof globalThis !== 'undefined' ? globalThis : typeof window !== 'undefined' ? window : typeof self !== 'undefined' ? self : this;
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
  } catch (e) {
    console.warn('[DSH Polyfill] 初始化异常:', e);
  }
})();
</script>`;

console.log(`[Runner] 正在启动 DeepSeek Harness 后台服务 (127.0.0.1:${DSH_PORT})...`);
console.log(`[Runner] 内置 API 端点: ${customBaseUrl}, 默认模型: ${customModel}, 推理强度: ${customReasoning}`);

// 确定与飞牛文件管理互通的工作区目录
let WORKSPACE_DIR = VAR_DIR;
if (fs.existsSync('/vol1/@appshare/DeepSeekHarness')) {
    WORKSPACE_DIR = '/vol1/@appshare/DeepSeekHarness';
} else if (fs.existsSync('/vol1')) {
    WORKSPACE_DIR = '/vol1';
}

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
