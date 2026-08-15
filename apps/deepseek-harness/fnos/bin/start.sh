#!/bin/bash
set -e

APP_DIR="${TRIM_APPDEST:-$(cd "$(dirname "$0")/.." && pwd)}"
APP_DATA_DIR="${TRIM_PKGVAR:-/tmp}"

export PATH="${APP_DIR}/bin:$PATH"
export HOME="${APP_DIR}"

INTERNAL_PORT=3081
PUBLIC_PORT=3080

echo "[Start] 启动 DeepSeek Harness (内部端口: ${INTERNAL_PORT})..."
"${APP_DIR}/bin/node" "${APP_DIR}/node_modules/@deepseek-ai/dsh/lib/bin.js" web --host 127.0.0.1 --port ${INTERNAL_PORT} &
DSH_PID=$!

echo "[Start] 启动透明反向代理 (公共端口: ${PUBLIC_PORT} -> ${INTERNAL_PORT})..."
PROXY_TARGET_PORT=${INTERNAL_PORT} PROXY_LISTEN_PORT=${PUBLIC_PORT} "${APP_DIR}/bin/node" "${APP_DIR}/bin/proxy.js" &
PROXY_PID=$!

trap 'echo "[Stop] 正在停止服务..."; kill ${DSH_PID} ${PROXY_PID} 2>/dev/null || true; exit 0' SIGTERM SIGINT

# 持续等待子进程
wait -n ${DSH_PID} ${PROXY_PID}
