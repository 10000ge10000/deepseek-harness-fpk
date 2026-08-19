#!/bin/bash
set -euo pipefail

# Build .fpk for DeepSeek Harness
# Usage: bash build-fpk.sh [version] [platform]
#   version  - override version (default: from manifest)
#   platform - x86 | arm (default: x86)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
APP_DIR="$REPO_ROOT/apps/deepseek-harness"
SHARED_DIR="$REPO_ROOT/shared"

VERSION="${1:-}"
PLATFORM="${2:-x86}"

case "$PLATFORM" in
    x86|x86_64|amd64)
        NORM_PLATFORM="x86"
        TAR_FILE="${REPO_ROOT}/app_amd64.tgz"
        ;;
    arm|arm64|aarch64)
        NORM_PLATFORM="arm"
        TAR_FILE="${REPO_ROOT}/app_arm64.tgz"
        ;;
    *)
        NORM_PLATFORM="$PLATFORM"
        TAR_FILE="${REPO_ROOT}/app_${PLATFORM}.tgz"
        ;;
esac

if [ ! -f "$TAR_FILE" ] && [ -f "${REPO_ROOT}/app.tgz" ]; then
    TAR_FILE="${REPO_ROOT}/app.tgz"
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

[ -d "$APP_DIR/fnos" ] || error "App directory not found: $APP_DIR/fnos"
[ -f "$TAR_FILE" ] || error "Target archive not found: $TAR_FILE — run build.sh first"

# Validate required files
for f in manifest cmd config ICON.PNG ICON_256.PNG; do
    [ -e "$APP_DIR/fnos/$f" ] || error "Missing: $APP_DIR/fnos/$f"
done
[ -d "$APP_DIR/fnos/ui" ] || error "Missing ui/ directory"

# Read appname
APPNAME=$(grep "^appname" "$APP_DIR/fnos/manifest" | awk -F'=' '{print $2}' | tr -d ' ')
[ -n "$APPNAME" ] || error "Cannot read appname from manifest"

info "Building fpk for: $APPNAME (platform: $NORM_PLATFORM)"

CHECKSUM=$(md5sum "$TAR_FILE" | cut -d' ' -f1)

WORK_DIR=$(mktemp -d)
PKG_DIR="$WORK_DIR/package"
mkdir -p "$PKG_DIR/cmd"

# 1. app.tgz
cp "$TAR_FILE" "$PKG_DIR/app.tgz"

# 2. shared cmd framework
for f in "$SHARED_DIR"/cmd/*; do
    case "$(basename "$f")" in
        *.md|*.MD) continue ;;
    esac
    cp "$f" "$PKG_DIR/cmd/"
done

# 3. app-specific cmd overrides (service-setup)
if [ -d "$APP_DIR/fnos/cmd" ]; then
    cp -a "$APP_DIR/fnos/cmd/." "$PKG_DIR/cmd/"
fi

# 4. config
if [ -d "$APP_DIR/fnos/config" ]; then
    cp -a "$APP_DIR/fnos/config" "$PKG_DIR/config"
fi

# 5. var seed
if [ -d "$APP_DIR/var" ]; then
    cp -a "$APP_DIR/var" "$PKG_DIR/"
fi

# 6. wizard (shared or app)
if [ -d "$APP_DIR/fnos/wizard" ]; then
    cp -a "$APP_DIR/fnos/wizard" "$PKG_DIR/"
elif [ -d "$SHARED_DIR/wizard" ]; then
    cp -a "$SHARED_DIR/wizard" "$PKG_DIR/"
fi

# 7. firewall sc
cp "$APP_DIR"/fnos/*.sc "$PKG_DIR/" 2>/dev/null || true

# 8. icons
cp "$APP_DIR"/fnos/ICON*.PNG "$PKG_DIR/" 2>/dev/null || true

# 9. ui
if [ -d "$APP_DIR/fnos/ui" ]; then
    cp -a "$APP_DIR/fnos/ui" "$PKG_DIR/"
fi
if [ -d "$PKG_DIR/ui/images" ] && [ -f "$PKG_DIR/ICON_256.PNG" ]; then
    cp "$PKG_DIR/ICON_256.PNG" "$PKG_DIR/ui/images/256.png"
fi

# 10. Ensure permissions for all directories and lifecycle scripts
find "$PKG_DIR" -type d -exec chmod 755 {} +
find "$PKG_DIR" -type f -exec chmod 644 {} +
chmod -R 755 "$PKG_DIR/cmd"
if [ -d "$PKG_DIR/wizard" ]; then
    chmod -R 755 "$PKG_DIR/wizard"
fi

# 11. manifest
cp "$APP_DIR/fnos/manifest" "$PKG_DIR/manifest"
if [ -n "$VERSION" ]; then
    sed -i.tmp "s/^version.*/version         = ${VERSION}/" "$PKG_DIR/manifest"
fi
if grep -q "^platform" "$PKG_DIR/manifest"; then
    sed -i.tmp "s/^platform.*/platform        = ${NORM_PLATFORM}/" "$PKG_DIR/manifest"
else
    echo "platform        = ${NORM_PLATFORM}" >> "$PKG_DIR/manifest"
fi
sed -i.tmp "s/^checksum.*/checksum        = ${CHECKSUM}/" "$PKG_DIR/manifest"
rm -f "$PKG_DIR/manifest.tmp"

# Output name
MANIFEST_VERSION=$(grep "^version" "$PKG_DIR/manifest" | awk -F'=' '{print $2}' | tr -d ' ')
MANIFEST_PLATFORM=$(grep "^platform" "$PKG_DIR/manifest" | awk -F'=' '{print $2}' | tr -d ' ')
FPK_NAME="${APPNAME}_${MANIFEST_VERSION}_${MANIFEST_PLATFORM:-x86}.fpk"

# 11. Create fpk
cd "$PKG_DIR"
[ -f "app.tgz" ] || error "app.tgz missing"
[ -f "manifest" ] || error "manifest missing"
[ -d "cmd" ] || error "cmd missing"
[ -d "config" ] || error "config missing"
[ -f "ICON.PNG" ] || error "ICON.PNG missing"
[ -f "ICON_256.PNG" ] || error "ICON_256.PNG missing"
tar -czf "$REPO_ROOT/$FPK_NAME" *
cd "$REPO_ROOT"

rm -rf "$WORK_DIR"
info "Built: $FPK_NAME ($(du -h "$REPO_ROOT/$FPK_NAME" | cut -f1))"
echo "$FPK_NAME"