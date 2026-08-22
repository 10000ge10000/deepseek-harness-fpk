#!/usr/bin/env bash
set -euo pipefail

# 解析本次构建的目标版本与发布策略（由 workflow 的 resolve_version job 调用）。
# 输入（环境变量，均由 GitHub Actions 注入或显式透传）：
#   EVENT_NAME         触发方式：schedule / workflow_dispatch / push
#   REF_NAME           触发引用名；tag 触发时形如 v0.1.2
#   VERSION_INPUT      dispatch 输入：发布版本号（可带 v 前缀，会规范化去掉）
#   DSH_VERSION_INPUT  dispatch 输入：上游 DSH npm 版本
#   FORCE_REBUILD      dispatch 输入：Release 已存在时是否仍强制重建
#   GITHUB_REPOSITORY  仓库 slug（gh release view 用）
#   GITHUB_OUTPUT      Actions output 文件（本地运行时可为空，仅打印）
# 输出：target_ver / dsh_ver / tag_name / should_build / publish_release

EVENT_NAME="${EVENT_NAME:-}"
REF_NAME="${REF_NAME:-}"
VERSION_INPUT="${VERSION_INPUT:-}"
DSH_VERSION_INPUT="${DSH_VERSION_INPUT:-}"
FORCE_REBUILD="${FORCE_REBUILD:-false}"

is_npm_version_ready() {
    local ver="$1"
    [ -z "$ver" ] && return 1
    npm view "@deepseek-ai/dsh@${ver}" version >/dev/null 2>&1
}

# 规范化：手动输入的版本号可能带 v 前缀，统一去掉避免拼出 vv 前缀 tag
VERSION_INPUT="${VERSION_INPUT#v}"
DSH_VERSION_INPUT="${DSH_VERSION_INPUT#v}"

APP_VER=$(grep "^version[[:space:]]*=" apps/deepseek-harness/fnos/manifest | awk -F'=' '{print $2}' | tr -d '[:space:]')

NPM_NEXT_VER=$(npm view @deepseek-ai/dsh dist-tags.next 2>/dev/null || true)
NPM_LATEST_VER=$(npm view @deepseek-ai/dsh dist-tags.latest 2>/dev/null || true)

# 版本兜底值以 meta.env 为单一来源
DSH_FALLBACK_VERSION=$(sed -n 's/^DSH_FALLBACK_VERSION=//p' scripts/apps/deepseek-harness/meta.env | tr -d '[:space:]')
[ -z "$DSH_FALLBACK_VERSION" ] && DSH_FALLBACK_VERSION="0.1.1-rc.2"

LATEST_NPM_VER=""
if is_npm_version_ready "$NPM_NEXT_VER"; then
    LATEST_NPM_VER="$NPM_NEXT_VER"
elif is_npm_version_ready "$NPM_LATEST_VER"; then
    LATEST_NPM_VER="$NPM_LATEST_VER"
else
    LATEST_NPM_VER="${APP_VER:-$DSH_FALLBACK_VERSION}"
fi

# tag 触发判定：push 事件且引用名以 v 开头（不再依赖隐式 GITHUB_REF）
IS_TAG=false
if [ "$EVENT_NAME" = "push" ] && [[ "$REF_NAME" == v* ]]; then
    IS_TAG=true
fi

if [ "$EVENT_NAME" = "schedule" ]; then
    # 定时任务以 npm 官方最新就绪版本为准，内核与 FPK 版本严格对齐
    TARGET_VER="$LATEST_NPM_VER"
    DSH_VER="$LATEST_NPM_VER"
elif [ -n "$VERSION_INPUT" ]; then
    # 用户显式指定构建版本
    TARGET_VER="$VERSION_INPUT"
    DSH_VER="${DSH_VERSION_INPUT:-$VERSION_INPUT}"
elif [ -n "$DSH_VERSION_INPUT" ]; then
    TARGET_VER="$DSH_VERSION_INPUT"
    DSH_VER="$DSH_VERSION_INPUT"
elif [ "$IS_TAG" = true ]; then
    # Tag 推送触发：版本严格与 Tag 对应，若 npm 存在对应包则优先使用该包；
    # tag 事件没有 dispatch 输入，npm 无包时回落最新就绪版本
    TAG_VER="${REF_NAME#v}"
    TARGET_VER="$TAG_VER"
    if is_npm_version_ready "$TAG_VER"; then
        DSH_VER="$TAG_VER"
    else
        DSH_VER="$LATEST_NPM_VER"
    fi
else
    # 自动推断：默认以官方最新可用版本为准，避免滞后于本地旧 manifest
    TARGET_VER="${LATEST_NPM_VER:-$APP_VER}"
    DSH_VER="${LATEST_NPM_VER:-$APP_VER}"
fi

if [ -z "$TARGET_VER" ] || [ -z "$DSH_VER" ]; then
    echo "无法确定 FPK 或 DSH 构建版本" >&2
    exit 1
fi

# 统一校验：解析出的 DSH 版本必须在 npm 真实存在，否则在 resolve 阶段
# 快速失败并给出可行动的提示（而不是拖到 ARM 构建才报 npm notarget）
if ! is_npm_version_ready "$DSH_VER"; then
    echo "DSH 版本 ${DSH_VER} 在 npm 上不存在（@deepseek-ai/dsh），" >&2
    echo "请确认 version / dsh_version 输入，或 npm registry 是否可达。" >&2
    exit 1
fi

if [ "$IS_TAG" = true ]; then
    RELEASE_TAG="$REF_NAME"
else
    RELEASE_TAG="v${TARGET_VER}"
fi

SHOULD_BUILD=true
PUBLISH_RELEASE=false
if [ "$EVENT_NAME" = "schedule" ]; then
    if [ "$TARGET_VER" = "${APP_VER:-}" ]; then
        SHOULD_BUILD=false
        echo "上游 DSH 仍为当前打包版本 ${TARGET_VER}，跳过构建。"
    elif gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
        SHOULD_BUILD=false
        echo "上游版本 ${TARGET_VER} 已有 Release ${RELEASE_TAG}，跳过重复构建。"
    else
        PUBLISH_RELEASE=true
    fi
elif [ "$EVENT_NAME" = "workflow_dispatch" ]; then
    # dispatch：Release 已存在且未勾选 force_rebuild 时跳过，行为与输入描述一致
    if gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
        if [ "$FORCE_REBUILD" = "true" ]; then
            echo "Release ${RELEASE_TAG} 已存在，按 force_rebuild 强制重建并覆盖资产。"
        else
            SHOULD_BUILD=false
            echo "Release ${RELEASE_TAG} 已存在且未勾选 force_rebuild，跳过构建。"
        fi
    fi
    [ "$SHOULD_BUILD" = true ] && PUBLISH_RELEASE=true
elif [ "$IS_TAG" = true ]; then
    PUBLISH_RELEASE=true
fi

if [ "$FORCE_REBUILD" = "true" ]; then
    SHOULD_BUILD=true
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "target_ver=${TARGET_VER}"
        echo "dsh_ver=${DSH_VER}"
        echo "tag_name=${RELEASE_TAG}"
        echo "should_build=${SHOULD_BUILD}"
        echo "publish_release=${PUBLISH_RELEASE}"
    } >> "$GITHUB_OUTPUT"
fi
echo "DSH=${DSH_VER}; FPK=${TARGET_VER}; Release=${RELEASE_TAG}; build=${SHOULD_BUILD}; publish=${PUBLISH_RELEASE}"
