#!/bin/bash
# deploy/verify.sh — 部署后验证
# 用法: ./deploy/verify.sh [dev|prod]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
set_env "${1:-dev}"

VERSION="$(get_version)"
BUILD="$(get_build)"
BASE_URL="https://${DOMAIN}"

# dev 环境 basic auth（从 config.local.sh 读取 DEV_AUTH_PASS）
CURL_OPTS=""
if [ "$ENV" = "dev" ] && [ -n "${DEV_AUTH_PASS:-}" ]; then
    CURL_OPTS="--user vowky:${DEV_AUTH_PASS}"
fi

PASS=0
FAIL=0

check_pass() { ((PASS++)); echo "  ✓ $1"; }
check_fail() { ((FAIL++)); echo "  ✗ $1"; }

echo "VowKy 部署验证 — ${ENV} (${DOMAIN})"
echo "============================================"

# 1. 网站可访问
echo ""
echo "[1/4] 检查网站..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" ${CURL_OPTS} "${BASE_URL}/" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    check_pass "网站返回 HTTP 200"
else
    check_fail "网站返回 HTTP ${HTTP_CODE}"
fi

# 2. 下载链接
echo ""
echo "[2/4] 检查下载链接..."
DL_CODE=$(curl -s -o /dev/null -w "%{http_code}" -I ${CURL_OPTS} "${BASE_URL}/downloads/VowKy-latest.dmg" 2>/dev/null || echo "000")
if [ "$DL_CODE" = "200" ] || [ "$DL_CODE" = "302" ]; then
    check_pass "DMG 下载链接有效 (HTTP ${DL_CODE})"
else
    check_fail "DMG 下载链接返回 HTTP ${DL_CODE}"
fi

# 3. HTTPS 证书
echo ""
echo "[3/4] 检查 HTTPS 证书..."
CERT_EXPIRY=$(echo | openssl s_client -servername "${DOMAIN}" -connect "${DOMAIN}:443" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null | grep notAfter | cut -d= -f2)
if [ -n "$CERT_EXPIRY" ]; then
    check_pass "HTTPS 证书有效，到期: ${CERT_EXPIRY}"
else
    check_fail "无法获取 HTTPS 证书信息"
fi

# 4. appcast.xml
echo ""
echo "[4/4] 检查 appcast.xml..."
APPCAST_CONTENT=$(curl -s ${CURL_OPTS} "${BASE_URL}/appcast.xml" 2>/dev/null || echo "")
if echo "$APPCAST_CONTENT" | grep -q "<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>"; then
    check_pass "appcast.xml 包含当前版本 v${VERSION}"
elif echo "$APPCAST_CONTENT" | grep -q "sparkle:shortVersionString"; then
    FOUND_VER=$(echo "$APPCAST_CONTENT" | grep -o '<sparkle:shortVersionString>[^<]*</sparkle:shortVersionString>' | head -1)
    check_fail "appcast.xml 版本不匹配: ${FOUND_VER} (期望 ${VERSION})"
else
    check_fail "appcast.xml 无法访问或格式错误"
fi

# 汇总
echo ""
echo "============================================"
echo "  结果: ✓ ${PASS} 通过  ✗ ${FAIL} 失败"
echo "  版本: v${VERSION} (${BUILD})"
echo "============================================"
[ "${FAIL}" -gt 0 ] && exit 1 || exit 0
