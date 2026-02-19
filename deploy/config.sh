#!/bin/bash
# deploy/config.sh — VowKy 部署共享配置
# 用法: source deploy/config.sh

set -euo pipefail

# ============================================================
# 加载本地私有配置
# ============================================================
_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "${_CONFIG_DIR}/config.local.sh" ]]; then
    echo "✗ 缺少 deploy/config.local.sh" >&2
    echo "  请复制 config.local.sh.example 为 config.local.sh 并填入你的配置" >&2
    exit 1
fi
source "${_CONFIG_DIR}/config.local.sh"

# ============================================================
# 路径
# ============================================================
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VOWKY_DIR="${REPO_ROOT}/VowKy"
WEBSITE_DIR="${REPO_ROOT}/website"
INFOPLIST="${VOWKY_DIR}/VowKy/Info.plist"
BUILD_DIR="${REPO_ROOT}/deploy/build"

# ============================================================
# 签名 & 公证
# ============================================================
DEV_IDENTITY="Apple Development"
# PROD_IDENTITY, TEAM_ID, NOTARY_PROFILE 从 config.local.sh 加载

# ============================================================
# 服务器
# ============================================================
# SERVER 从 config.local.sh 加载
DOMAIN="vowky.com"
WEB_ROOT="/var/www/vowky/prod"

# ============================================================
# 环境变量（固定 prod）
# ============================================================
ENV="prod"
SIGN_IDENTITY="$PROD_IDENTITY"
NOTARIZE=true
export ENV SIGN_IDENTITY DOMAIN WEB_ROOT NOTARIZE

# ============================================================
# 辅助函数
# ============================================================

# 从 Info.plist 读取版本号 (CFBundleShortVersionString)
get_version() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFOPLIST"
}

# 从 Info.plist 读取 build number (CFBundleVersion)
get_build() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFOPLIST"
}

# 格式化输出
log_info()  { echo "▸ $*"; }
log_ok()    { echo "✓ $*"; }
log_warn()  { echo "⚠ $*"; }
log_error() { echo "✗ $*" >&2; }
