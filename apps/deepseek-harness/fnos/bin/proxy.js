/**
 * DeepSeek Harness - fnOS 本地透明反向代理
 * 监听 0.0.0.0:3080，将外部局域网请求及 WebSocket 透明转发至 127.0.0.1:3081
 * 原生 Node.js 实现，零外部依赖，支持 SSE 流式传输与 WebSocket 双向通讯
 * 自动为非 HTTPS 局域网环境注入 crypto.randomUUID Polyfill (解决浏览器安全上下文限制)
 */

const http = require('http');
const net = require('net');

const LISTEN_HOST = process.env.PROXY_LISTEN_HOST || '0.0.0.0';
const LISTEN_PORT = parseInt(process.env.PROXY_LISTEN_PORT || '3080', 10);
const TARGET_HOST = process.env.PROXY_TARGET_HOST || '127.0.0.1';
const TARGET_PORT = parseInt(process.env.PROXY_TARGET_PORT || '3081', 10);

// Polyfill 脚本：解决局域网 HTTP 下由于浏览器 Secure Context 策略导致 crypto.randomUUID 不可用的问题
const POLYFILL_SCRIPT = `<script>
(function() {
  try {
    if (typeof window !== 'undefined') {
      if (!window.crypto) window.crypto = {};
      if (!window.crypto.randomUUID) {
        window.crypto.randomUUID = function() {
          if (window.crypto.getRandomValues) {
            return ([1e7]+-1e3+-4e3+-8e3+-1e11).replace(/[018]/g, function(c) {
              return (c ^ (window.crypto.getRandomValues(new Uint8Array(1))[0] & (15 >> (c / 4)))).toString(16);
            });
          }
          return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
            var r = Math.random() * 16 | 0, v = c === 'x' ? r : (r & 0x3 | 0x8);
            return v.toString(16);
          });
        };
      }
    }
  } catch (e) {
    console.warn('[Polyfill] crypto.randomUUID polyfill init error:', e);
  }
})();
</script>`;

const server = http.createServer((clientReq, clientRes) => {
    // 移除客户端请求中的 accept-encoding，确保返回明文 html 便于注入 polyfill
    const headers = {
        ...clientReq.headers,
        'x-forwarded-for': clientReq.socket.remoteAddress,
        'x-forwarded-proto': 'http',
        'x-forwarded-host': clientReq.headers.host || `${LISTEN_HOST}:${LISTEN_PORT}`,
        host: `${TARGET_HOST}:${TARGET_PORT}`
    };

    const isHtmlPath = clientReq.url === '/' || clientReq.url.endsWith('.html') || !clientReq.url.includes('.');
    if (isHtmlPath) {
        delete headers['accept-encoding'];
    }

    const options = {
        hostname: TARGET_HOST,
        port: TARGET_PORT,
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

                clientRes.writeHead(proxyRes.statusCode, resHeaders);
                clientRes.end(body);
            });
        } else {
            clientRes.writeHead(proxyRes.statusCode, proxyRes.headers);
            proxyRes.pipe(clientRes, { end: true });
        }
    });

    proxyReq.on('error', (err) => {
        console.error(`[Proxy] 请求转发失败 (${clientReq.method} ${clientReq.url}):`, err.message);
        if (!clientRes.headersSent) {
            clientRes.writeHead(502, { 'Content-Type': 'text/html; charset=utf-8' });
            clientRes.end('<h3>DeepSeek Harness 服务启动中，请稍候刷新...</h3>');
        }
    });

    clientReq.pipe(proxyReq, { end: true });
});

// 处理 WebSocket / HTTP Upgrade
server.on('upgrade', (req, socket, head) => {
    const proxySocket = net.connect(TARGET_PORT, TARGET_HOST, () => {
        proxySocket.write(
            `${req.method} ${req.url} HTTP/${req.httpVersion}\r\n` +
            Object.entries(req.headers)
                .map(([k, v]) => `${k}: ${v}`)
                .join('\r\n') +
            '\r\n\r\n'
        );
        if (head && head.length) proxySocket.write(head);
        socket.pipe(proxySocket);
        proxySocket.pipe(socket);
    });

    proxySocket.on('error', (err) => {
        console.error('[Proxy WebSocket] 连接失败:', err.message);
        socket.destroy();
    });

    socket.on('error', (err) => {
        console.error('[Client WebSocket] 连接异常:', err.message);
        proxySocket.destroy();
    });
});

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
    console.log(`[Proxy] 正在监听 http://${LISTEN_HOST}:${LISTEN_PORT} -> http://${TARGET_HOST}:${TARGET_PORT}`);
});

process.on('SIGTERM', () => {
    server.close(() => process.exit(0));
});

process.on('SIGINT', () => {
    server.close(() => process.exit(0));
});
