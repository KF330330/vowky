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
DMG_NAME="VowKy-${VERSION}.dmg"

ARCHIVE_DIR="${BUILD_DIR}/archive"
APP_DIR="${BUILD_DIR}/app"
DMG_DIR="${BUILD_DIR}/dmg"
ARCHIVE_PATH="${ARCHIVE_DIR}/VowKy.xcarchive"
APP_PATH="${APP_DIR}/VowKy.app"
HELPER_PATH="${APP_PATH}/Contents/Helpers/vowky-transcribe"
DMG_PATH="${DMG_DIR}/${DMG_NAME}"
NOTARY_UPLOAD_DIR=""

cleanup_notary_upload_dir() {
    if [ -n "${NOTARY_UPLOAD_DIR}" ] && [ -d "${NOTARY_UPLOAD_DIR}" ]; then
        rm -rf "${NOTARY_UPLOAD_DIR}"
    fi
}
trap cleanup_notary_upload_dir EXIT

log_info "构建 VowKy v${VERSION} (${BUILD}) — 环境: ${ENV}"

REQUIRED_ARCHS=("arm64" "x86_64")

check_binary_archs() {
    local binary="$1"
    local label="$2"
    local archs

    if [ ! -f "$binary" ]; then
        log_error "${label} 不存在: ${binary}"
        exit 1
    fi

    archs="$(lipo -archs "$binary")"
    for required_arch in "${REQUIRED_ARCHS[@]}"; do
        if [[ " ${archs} " != *" ${required_arch} "* ]]; then
            log_error "${label} 缺少 ${required_arch} 架构: ${archs}"
            log_error "请确认 xcodebuild 使用 generic macOS destination 并构建 ${REQUIRED_ARCHS[*]}"
            exit 1
        fi
    done

    log_ok "${label} 架构: ${archs}"
}

check_app_signature() {
    local app_path="$1"
    local label="$2"
    local entitlements

    codesign --verify --deep --strict --verbose=4 "$app_path"
    entitlements="$(codesign -d --entitlements - "$app_path" 2>/dev/null || true)"
    if ! grep -q "com.apple.security.device.audio-input" <<< "$entitlements"; then
        log_error "${label} 缺少麦克风 entitlement"
        exit 1
    fi
    if ! grep -q "com.apple.security.cs.allow-unsigned-executable-memory" <<< "$entitlements"; then
        log_error "${label} 缺少 ONNX runtime entitlement"
        exit 1
    fi

    log_ok "${label} 签名和 entitlements 验证通过"
}

check_helper_signature() {
    local helper_path="$1"
    local label="$2"
    local entitlements

    codesign --verify --strict --verbose=4 "$helper_path"
    entitlements="$(codesign -d --entitlements - "$helper_path" 2>/dev/null || true)"
    if ! grep -q "com.apple.security.cs.allow-unsigned-executable-memory" <<< "$entitlements"; then
        log_error "${label} 缺少 ONNX runtime entitlement"
        exit 1
    fi
    if grep -q "com.apple.security.device.audio-input" <<< "$entitlements"; then
        log_error "${label} 不应包含麦克风 entitlement"
        exit 1
    fi

    log_ok "${label} 签名和 entitlements 验证通过"
}

verify_dmg_contents() {
    local mount_dir
    mount_dir="$(mktemp -d "${TMPDIR:-/tmp}/vowky-dmg.XXXXXX")"

    hdiutil attach -nobrowse -readonly -mountpoint "$mount_dir" "$DMG_PATH" >/dev/null
    check_binary_archs "${mount_dir}/VowKy.app/Contents/MacOS/VowKy" "DMG 内 VowKy 主程序"
    check_binary_archs "${mount_dir}/VowKy.app/Contents/Helpers/vowky-transcribe" "DMG 内 vowky-transcribe helper"
    check_helper_signature "${mount_dir}/VowKy.app/Contents/Helpers/vowky-transcribe" "DMG 内 vowky-transcribe helper"
    check_app_signature "${mount_dir}/VowKy.app" "DMG 内 VowKy.app"
    hdiutil detach "$mount_dir" >/dev/null
    rmdir "$mount_dir"
}

# ============================================================
# 清理 & 创建目录
# ============================================================
rm -rf "${BUILD_DIR}"
mkdir -p "${ARCHIVE_DIR}" "${APP_DIR}" "${DMG_DIR}"
if [ "$NOTARIZE" = true ]; then
    # notarytool 从 Nutstore 同步目录直传大文件时容易 deadlineExceeded。
    # 先复制到本机临时目录再提交，上传稳定性明显更好。
    NOTARY_UPLOAD_DIR="$(mktemp -d "/private/tmp/vowky-notary.XXXXXX")"
fi

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
# Archive 默认用 Apple Development（避免 Developer ID 的 timestamp 问题）
# prod 环境在后续 step 4 重签为 Developer ID。
# 本机没有 Apple Development 证书时，用 DEV_IDENTITY="Developer ID Application"
# DEV_CODE_SIGN_STYLE=Manual 覆盖（手动指定身份必须配 Manual，否则与自动签名冲突）
xcodebuild archive \
    -project "${VOWKY_DIR}/VowKy.xcodeproj" \
    -scheme VowKy \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "${ARCHIVE_PATH}" \
    CODE_SIGN_IDENTITY="${DEV_IDENTITY}" \
    CODE_SIGN_STYLE="${DEV_CODE_SIGN_STYLE:-Automatic}" \
    DEVELOPMENT_TEAM="${TEAM_ID}" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    OTHER_CODE_SIGN_FLAGS="--options=runtime" \
    | tail -5
log_ok "Archive 完成"

# ============================================================
# 3. 导出 App
# ============================================================
log_info "从 Archive 导出 App..."
cp -R "${ARCHIVE_PATH}/Products/Applications/VowKy.app" "${APP_PATH}"
log_ok "App 导出到 ${APP_PATH}"

# 防止在 Apple Silicon 构建机上误产出 arm64-only 包，导致 Intel Mac 无法打开。
check_binary_archs "${APP_PATH}/Contents/MacOS/VowKy" "VowKy 主程序"
check_binary_archs "${HELPER_PATH}" "vowky-transcribe helper"
check_binary_archs "${APP_PATH}/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" "Sparkle.framework"
check_binary_archs "${APP_PATH}/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" "Sparkle Autoupdate"

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

sign_main_app() {
    # 主 app 必须带 entitlements；否则麦克风权限会被 TCC 静默拒绝。
    if [ "$NOTARIZE" = true ]; then
        codesign_with_retry --force --sign "${SIGN_IDENTITY}" --options runtime --timestamp --entitlements "${VOWKY_DIR}/VowKy/VowKy.entitlements" "${APP_PATH}"
    else
        codesign --force --sign "${SIGN_IDENTITY}" --options runtime --timestamp=none --entitlements "${VOWKY_DIR}/VowKy/VowKy.entitlements" "${APP_PATH}"
    fi
}

sign_transcribe_helper() {
    # helper 不需要麦克风权限，只需要 ONNX runtime entitlement。
    if [ "$NOTARIZE" = true ]; then
        codesign_with_retry --force --sign "${SIGN_IDENTITY}" --options runtime --timestamp --entitlements "${VOWKY_DIR}/VowKyTranscribe.entitlements" "${HELPER_PATH}"
    else
        codesign --force --sign "${SIGN_IDENTITY}" --options runtime --timestamp=none --entitlements "${VOWKY_DIR}/VowKyTranscribe.entitlements" "${HELPER_PATH}"
    fi
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
    # 3. 签名 helper
fi
sign_transcribe_helper
# 4. 签名主 app（必须传 --entitlements，否则重签会丢失 entitlements）
sign_main_app
log_ok "代码签名完成"

# 验证签名
check_helper_signature "${HELPER_PATH}" "vowky-transcribe helper"
check_app_signature "${APP_PATH}" "VowKy.app"

# ============================================================
# 公证认证参数：优先用环境变量直传 Apple ID + 专用密码（绕过本机不稳定的
# keychain，item 会反复消失），否则回退到 keychain profile。
# 用法：NOTARY_APPLE_ID=... NOTARY_PASSWORD=... make deploy
# ============================================================
if [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
    NOTARY_AUTH_ARGS=(--apple-id "${NOTARY_APPLE_ID}" --team-id "${TEAM_ID}" --password "${NOTARY_PASSWORD}")
    log_info "公证认证：环境变量直传（${NOTARY_APPLE_ID}），已绕过 keychain"
else
    NOTARY_AUTH_ARGS=(--keychain-profile "${NOTARY_PROFILE}")
fi

# ============================================================
# 5. 公证 App (仅 prod)
# ============================================================
if [ "$NOTARIZE" = true ]; then
    log_info "公证 App..."
    # 创建临时 zip 用于公证
    APP_ZIP="${NOTARY_UPLOAD_DIR}/VowKy-notarize.zip"
    ditto -c -k --keepParent "${APP_PATH}" "${APP_ZIP}"

    # NOTARY_NO_S3_ACCEL=1：禁用 S3 传输加速端点（国内网络上传大包时加速端点反而易超时）
    xcrun notarytool submit "${APP_ZIP}" \
        "${NOTARY_AUTH_ARGS[@]}" \
        ${NOTARY_NO_S3_ACCEL:+--no-s3-acceleration} \
        --wait

    xcrun stapler staple "${APP_PATH}"
    log_ok "App 公证完成"
    rm -f "${APP_ZIP}"

    # 在部分同步目录或钥匙串状态下，staple 后 CMS 可能变成不可验证。
    # 重新签主 app 不改变 CodeDirectory/CDHash，保留公证票据，但能恢复可验证证书链。
    log_info "重新签名并验证 stapled App..."
    sign_transcribe_helper
    sign_main_app
    xcrun stapler validate "${APP_PATH}"
    check_helper_signature "${HELPER_PATH}" "stapled vowky-transcribe helper"
    check_app_signature "${APP_PATH}" "stapled VowKy.app"
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
    DMG_NOTARY_PATH="${NOTARY_UPLOAD_DIR}/${DMG_NAME}"
    cp "${DMG_PATH}" "${DMG_NOTARY_PATH}"

    xcrun notarytool submit "${DMG_NOTARY_PATH}" \
        "${NOTARY_AUTH_ARGS[@]}" \
        ${NOTARY_NO_S3_ACCEL:+--no-s3-acceleration} \
        --wait

    xcrun stapler staple "${DMG_PATH}"
    log_ok "DMG 公证完成"
fi

verify_dmg_contents

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
