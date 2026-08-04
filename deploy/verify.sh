#!/bin/bash
# deploy/verify.sh — 部署后验证
# 用法: ./deploy/verify.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

VERSION="$(get_version)"
BUILD="$(get_build)"
BASE_URL="https://${DOMAIN}"

PASS=0
FAIL=0

check_pass() { ((PASS++)); echo "  ✓ $1"; }
check_fail() { ((FAIL++)); echo "  ✗ $1"; }

echo "VowKy 部署验证 — ${DOMAIN}"
echo "============================================"

# 1. 网站可访问
echo ""
echo "[1/4] 检查网站..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    check_pass "网站返回 HTTP 200"
else
    check_fail "网站返回 HTTP ${HTTP_CODE}"
fi

# 2. 下载链接
echo ""
echo "[2/4] 检查下载链接..."
DL_CODE=$(curl -s -o /dev/null -w "%{http_code}" -I "${BASE_URL}/downloads/VowKy-latest.dmg" 2>/dev/null || echo "000")
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
echo "[4/5] 检查 appcast.xml..."
APPCAST_CONTENT=$(curl -s "${BASE_URL}/appcast.xml" 2>/dev/null || echo "")
if echo "$APPCAST_CONTENT" | grep -q "<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>"; then
    check_pass "appcast.xml 包含当前版本 v${VERSION}"
elif echo "$APPCAST_CONTENT" | grep -q "sparkle:shortVersionString"; then
    FOUND_VER=$(echo "$APPCAST_CONTENT" | grep -o '<sparkle:shortVersionString>[^<]*</sparkle:shortVersionString>' | head -1)
    check_fail "appcast.xml 版本不匹配: ${FOUND_VER} (期望 ${VERSION})"
else
    check_fail "appcast.xml 无法访问或格式错误"
fi

# 5. delta 增量包(如 appcast 带 deltas 块则校验可下载且 length 一致;不带=全量更新,允许)
echo ""
echo "[5/5] 检查 delta 增量包..."
if echo "$APPCAST_CONTENT" | grep -q "<sparkle:deltas>"; then
    DELTA_URL=$(echo "$APPCAST_CONTENT" | sed -n '/<sparkle:deltas>/,/<\/sparkle:deltas>/p' | grep -o 'url="[^"]*"' | head -1 | sed 's/^url="//;s/"$//')
    DELTA_LEN=$(echo "$APPCAST_CONTENT" | sed -n '/<sparkle:deltas>/,/<\/sparkle:deltas>/p' | grep -o 'length="[^"]*"' | head -1 | sed 's/^length="//;s/"$//')
    DELTA_FROM=$(echo "$APPCAST_CONTENT" | sed -n '/<sparkle:deltas>/,/<\/sparkle:deltas>/p' | grep -o 'sparkle:deltaFrom="[^"]*"' | head -1 | sed 's/^sparkle:deltaFrom="//;s/"$//')
    if [ -z "${DELTA_URL}" ] || [ -z "${DELTA_FROM}" ]; then
        check_fail "deltas 块格式异常(缺 url 或 deltaFrom)"
    else
        REMOTE_LEN=$(curl -s -o /dev/null -w "%{http_code} %{size_download}" -I "${DELTA_URL}" 2>/dev/null || echo "000")
        DELTA_HTTP="${REMOTE_LEN%% *}"
        REMOTE_CONTENT_LEN=$(curl -sI "${DELTA_URL}" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}' | head -1)
        if [ "${DELTA_HTTP}" != "200" ]; then
            check_fail "delta 不可下载 (HTTP ${DELTA_HTTP}): ${DELTA_URL}"
        elif [ -n "${REMOTE_CONTENT_LEN}" ] && [ "${REMOTE_CONTENT_LEN}" != "${DELTA_LEN}" ]; then
            check_fail "delta length 不一致: appcast=${DELTA_LEN} 实际=${REMOTE_CONTENT_LEN}"
        else
            check_pass "delta 就绪 (deltaFrom=${DELTA_FROM}, ${DELTA_LEN}B): ${DELTA_URL##*/}"
        fi
    fi
else
    check_pass "appcast 无 deltas 块(本版走全量更新,允许)"
fi

# 汇总
echo ""
echo "============================================"
echo "  结果: ✓ ${PASS} 通过  ✗ ${FAIL} 失败"
echo "  版本: v${VERSION} (${BUILD})"
echo "============================================"
[ "${FAIL}" -gt 0 ] && exit 1 || exit 0
