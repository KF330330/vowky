#!/bin/bash
# deploy/deploy.sh — VowKy 主部署入口
# 用法: ./deploy/deploy.sh
# 步骤: 构建 → 上传网站 → 上传 DMG → 生成 appcast.xml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

log_info "部署 VowKy → ${DOMAIN}"

# ============================================================
# 1. 构建
# ============================================================
log_info "开始构建..."
"${SCRIPT_DIR}/build.sh"

VERSION="$(get_version)"
BUILD="$(get_build)"
DMG_NAME="VowKy-${VERSION}-${BUILD}.dmg"
DMG_PATH="${BUILD_DIR}/dmg/${DMG_NAME}"

if [ ! -f "${DMG_PATH}" ]; then
    log_error "DMG 不存在: ${DMG_PATH}"
    exit 1
fi

# ============================================================
# 2. 上传网站（替换下载链接为带版本号的文件名）
# ============================================================
log_info "上传网站到 ${SERVER}:${WEB_ROOT}/site/..."
ssh "${SERVER}" "mkdir -p ${WEB_ROOT}/site ${WEB_ROOT}/downloads"

# 创建临时目录，替换下载链接后上传
SITE_STAGING="${BUILD_DIR}/site-staging"
rm -rf "${SITE_STAGING}"
cp -R "${WEBSITE_DIR}" "${SITE_STAGING}"
sed -i '' "s|VowKy-latest\.dmg|${DMG_NAME}|g" "${SITE_STAGING}/index.html"
log_info "下载链接已替换为 ${DMG_NAME}"

rsync -avz --delete \
    "${SITE_STAGING}/" \
    "${SERVER}:${WEB_ROOT}/site/"
rm -rf "${SITE_STAGING}"
log_ok "网站上传完成"

# ============================================================
# 3. 上传 DMG
# ============================================================
log_info "上传 DMG 到 ${SERVER}:${WEB_ROOT}/downloads/..."
rsync -avz \
    "${DMG_PATH}" \
    "${SERVER}:${WEB_ROOT}/downloads/"
log_ok "DMG 上传完成: ${DMG_NAME}"

# 创建 latest 符号链接
log_info "创建 VowKy-latest.dmg 符号链接..."
ssh "${SERVER}" "cd ${WEB_ROOT}/downloads && ln -sf '${DMG_NAME}' VowKy-latest.dmg"
log_ok "符号链接已创建"

# ============================================================
# 4. 生成 appcast.xml
# ============================================================
log_info "生成 appcast.xml..."

DMG_SIZE_BYTES=$(wc -c < "${DMG_PATH}" | tr -d ' ')
PUB_DATE=$(date -u +"%a, %d %b %Y %H:%M:%S %z")
DOWNLOAD_URL="https://${DOMAIN}/downloads/${DMG_NAME}"
LATEST_URL="https://${DOMAIN}/downloads/VowKy-latest.dmg"

# 尝试用 Sparkle sign_update 签名
SPARKLE_SIGNATURE=""
SIGN_UPDATE_BIN=""

# 查找 sign_update 工具
for candidate in \
    "$(which sign_update 2>/dev/null || true)" \
    "/usr/local/bin/sign_update" \
    "${HOME}/Library/Developer/Sparkle/bin/sign_update" \
    "$(find /Applications -name sign_update -maxdepth 5 2>/dev/null | head -1)" \
    "$(find "${HOME}/Library/Developer" -name sign_update -maxdepth 5 2>/dev/null | head -1)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        SIGN_UPDATE_BIN="$candidate"
        break
    fi
done

if [ -n "$SIGN_UPDATE_BIN" ]; then
    log_info "使用 Sparkle sign_update: ${SIGN_UPDATE_BIN}"
    SPARKLE_SIGNATURE=$("${SIGN_UPDATE_BIN}" "${DMG_PATH}" 2>/dev/null || true)
    if [ -n "$SPARKLE_SIGNATURE" ]; then
        log_ok "EdDSA 签名成功"
    else
        log_warn "sign_update 执行失败，跳过 EdDSA 签名"
    fi
else
    log_warn "未找到 Sparkle sign_update 工具，跳过 EdDSA 签名"
    log_warn "安装后运行: brew install sparkle"
fi

# 构建 sparkle:edSignature 属性
EDDSA_ATTR=""
if [ -n "$SPARKLE_SIGNATURE" ]; then
    # sign_update 输出格式: sparkle:edSignature="xxx" length="yyy"
    EDDSA_ATTR=" ${SPARKLE_SIGNATURE}"
fi

# 生成 appcast.xml
APPCAST_PATH="${BUILD_DIR}/appcast.xml"
cat > "${APPCAST_PATH}" <<APPCAST_EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>VowKy Updates</title>
    <link>https://${DOMAIN}/appcast.xml</link>
    <description>VowKy 更新</description>
    <language>zh-cn</language>
    <item>
      <title>VowKy ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure url="${DOWNLOAD_URL}" length="${DMG_SIZE_BYTES}" type="application/octet-stream"${EDDSA_ATTR} />
    </item>
  </channel>
</rss>
APPCAST_EOF

log_ok "appcast.xml 已生成: ${APPCAST_PATH}"

# 尝试用 Sparkle generate_appcast (如果有)
GENERATE_APPCAST_BIN=""
for candidate in \
    "$(which generate_appcast 2>/dev/null || true)" \
    "/usr/local/bin/generate_appcast" \
    "${HOME}/Library/Developer/Sparkle/bin/generate_appcast" \
    "$(find /Applications -name generate_appcast -maxdepth 5 2>/dev/null | head -1)" \
    "$(find "${HOME}/Library/Developer" -name generate_appcast -maxdepth 5 2>/dev/null | head -1)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        GENERATE_APPCAST_BIN="$candidate"
        break
    fi
done

if [ -n "$GENERATE_APPCAST_BIN" ]; then
    log_info "使用 Sparkle generate_appcast 重新生成..."
    "${GENERATE_APPCAST_BIN}" "${DMG_DIR}" -o "${APPCAST_PATH}" 2>/dev/null || {
        log_warn "generate_appcast 失败，使用手动生成的 appcast.xml"
    }
fi

# ============================================================
# 5. 上传 appcast.xml
# ============================================================
log_info "上传 appcast.xml..."
rsync -avz \
    "${APPCAST_PATH}" \
    "${SERVER}:${WEB_ROOT}/site/appcast.xml"
# Nginx 期望 appcast.xml 在 WEB_ROOT 根目录，创建软链接
ssh "${SERVER}" "ln -sf ${WEB_ROOT}/site/appcast.xml ${WEB_ROOT}/appcast.xml"
log_ok "appcast.xml 上传完成"

# ============================================================
# 输出摘要
# ============================================================
echo ""
echo "============================================"
echo "  部署完成"
echo "============================================"
echo "  版本:     ${VERSION} (${BUILD})"
echo "  环境:     ${ENV}"
echo "  网站:     https://${DOMAIN}/"
echo "  下载:     ${LATEST_URL}"
echo "  Appcast:  https://${DOMAIN}/appcast.xml"
echo "============================================"
