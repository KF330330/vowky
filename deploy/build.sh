#!/bin/bash
# deploy/build.sh — VowKy 构建流程
# 用法: ./deploy/build.sh
# 输出: deploy/build/dmg/VowKy-{version}-{build}.dmg

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# ============================================================
# 环境（固定 prod，config.sh 已设置）
# ============================================================

# 支持 SKIP_NOTARIZE=1 跳过公证（Apple timestamp 不可用时使用）
if [ "${SKIP_NOTARIZE:-}" = "1" ]; then
    NOTARIZE=false
    export NOTARIZE
fi

VERSION="$(get_version)"
BUILD="$(get_build)"
DMG_NAME="VowKy-${VERSION}-${BUILD}.dmg"

ARCHIVE_DIR="${BUILD_DIR}/archive"
APP_DIR="${BUILD_DIR}/app"
DMG_DIR="${BUILD_DIR}/dmg"
ARCHIVE_PATH="${ARCHIVE_DIR}/VowKy.xcarchive"
APP_PATH="${APP_DIR}/VowKy.app"
DMG_PATH="${DMG_DIR}/${DMG_NAME}"

log_info "构建 VowKy v${VERSION} (${BUILD}) — 环境: ${ENV}"

# ============================================================
# 清理 & 创建目录
# ============================================================
rm -rf "${BUILD_DIR}"
mkdir -p "${ARCHIVE_DIR}" "${APP_DIR}" "${DMG_DIR}"

# ============================================================
# 1. xcodegen generate
# ============================================================
log_info "生成 Xcode 项目..."
cd "${VOWKY_DIR}"
xcodegen generate
log_ok "Xcode 项目已生成"

# ============================================================
# 2. xcodebuild archive
# ============================================================
log_info "构建 Archive (Release)..."
# Archive 始终用 Apple Development（避免 Developer ID 的 timestamp 问题）
# prod 环境在后续 step 4 重签为 Developer ID
xcodebuild archive \
    -project "${VOWKY_DIR}/VowKy.xcodeproj" \
    -scheme VowKy \
    -configuration Release \
    -archivePath "${ARCHIVE_PATH}" \
    CODE_SIGN_IDENTITY="${DEV_IDENTITY}" \
    DEVELOPMENT_TEAM="${TEAM_ID}" \
    OTHER_CODE_SIGN_FLAGS="--options=runtime" \
    | tail -5
log_ok "Archive 完成"

# ============================================================
# 3. 导出 App
# ============================================================
log_info "从 Archive 导出 App..."
cp -R "${ARCHIVE_PATH}/Products/Applications/VowKy.app" "${APP_PATH}"
log_ok "App 导出到 ${APP_PATH}"

# ============================================================
# 4. 代码签名 (hardened runtime)
# ============================================================
log_info "代码签名 (${SIGN_IDENTITY})..."
codesign_with_retry() {
    local max_retries=3
    for i in $(seq 1 $max_retries); do
        if codesign "$@" 2>&1; then
            return 0
        fi
        if [ "$i" -lt "$max_retries" ]; then
            log_warn "签名失败，${i}/${max_retries} 重试中 (等待 5 秒)..."
            sleep 5
        fi
    done
    log_error "签名失败，已重试 ${max_retries} 次"
    return 1
}

if [ "$NOTARIZE" = true ]; then
    # prod: 从内到外递归签名所有二进制（公证要求每个二进制都有 Developer ID + timestamp）
    # 1. 签名 Sparkle 内嵌的 XPC 服务和辅助 app
    find "${APP_PATH}/Contents/Frameworks" -name "*.xpc" -o -name "*.app" -o -name "Autoupdate" | sort -r | while read -r item; do
        [ -e "$item" ] && codesign_with_retry --force --sign "${SIGN_IDENTITY}" --options runtime --timestamp "$item"
    done
    # 2. 签名 framework 顶层
    for fw in "${APP_PATH}/Contents/Frameworks/"*.framework; do
        [ -d "$fw" ] && codesign_with_retry --force --sign "${SIGN_IDENTITY}" --options runtime --timestamp "$fw"
    done
    # 3. 签名主 app（必须传 --entitlements，否则重签会丢失 entitlements）
    codesign_with_retry --force --sign "${SIGN_IDENTITY}" --options runtime --timestamp --entitlements "${VOWKY_DIR}/VowKy/VowKy.entitlements" "${APP_PATH}"
else
    # 不公证：显式禁用 timestamp（Developer ID 会自动尝试）
    codesign --force --deep --sign "${SIGN_IDENTITY}" --options runtime --timestamp=none --entitlements "${VOWKY_DIR}/VowKy/VowKy.entitlements" "${APP_PATH}"
fi
log_ok "代码签名完成"

# 验证签名
codesign --verify --deep --strict "${APP_PATH}"
log_ok "签名验证通过"

# ============================================================
# 5. 公证 App (仅 prod)
# ============================================================
if [ "$NOTARIZE" = true ]; then
    log_info "公证 App..."
    # 创建临时 zip 用于公证
    APP_ZIP="${BUILD_DIR}/VowKy-notarize.zip"
    ditto -c -k --keepParent "${APP_PATH}" "${APP_ZIP}"

    xcrun notarytool submit "${APP_ZIP}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait

    xcrun stapler staple "${APP_PATH}"
    log_ok "App 公证完成"
    rm -f "${APP_ZIP}"
fi

# ============================================================
# 6. 创建 DMG
# ============================================================
log_info "创建 DMG..."

# 创建临时 DMG 目录，放入 App 和 Applications 快捷方式
DMG_STAGING="${BUILD_DIR}/dmg-staging"
mkdir -p "${DMG_STAGING}"
cp -R "${APP_PATH}" "${DMG_STAGING}/VowKy.app"
ln -s /Applications "${DMG_STAGING}/Applications"

hdiutil create \
    -volname "VowKy ${VERSION}" \
    -srcfolder "${DMG_STAGING}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

rm -rf "${DMG_STAGING}"
log_ok "DMG 创建完成: ${DMG_PATH}"

# ============================================================
# 7. 签名 DMG
# ============================================================
log_info "签名 DMG..."
if [ "$NOTARIZE" = true ]; then
    codesign_with_retry --force --sign "${SIGN_IDENTITY}" --timestamp "${DMG_PATH}"
else
    codesign --force --sign "${SIGN_IDENTITY}" --timestamp=none "${DMG_PATH}"
fi
log_ok "DMG 签名完成"

# ============================================================
# 8. 公证 DMG (仅 prod)
# ============================================================
if [ "$NOTARIZE" = true ]; then
    log_info "公证 DMG..."
    xcrun notarytool submit "${DMG_PATH}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait

    xcrun stapler staple "${DMG_PATH}"
    log_ok "DMG 公证完成"
fi

# ============================================================
# 输出摘要
# ============================================================
DMG_SIZE=$(du -h "${DMG_PATH}" | cut -f1)
echo ""
echo "============================================"
echo "  构建完成"
echo "============================================"
echo "  版本:   ${VERSION} (${BUILD})"
echo "  环境:   ${ENV}"
echo "  DMG:    ${DMG_PATH}"
echo "  大小:   ${DMG_SIZE}"
echo "  签名:   ${SIGN_IDENTITY}"
if [ "$NOTARIZE" = true ]; then
    echo "  公证:   已完成"
fi
echo "============================================"
