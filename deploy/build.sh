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
SPEECH_HELPER_PATH="${APP_PATH}/Contents/Helpers/vowky-speechd"
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
    # 主 app 不再持有 allow-unsigned-executable-memory(ONNX 已移出主进程到 vowky-speechd helper)。
    # 若主 app 仍带此 entitlement,说明 ONNX 又被链回主进程 —— 视为治本回退,直接失败。
    if grep -q "com.apple.security.cs.allow-unsigned-executable-memory" <<< "$entitlements"; then
        log_error "${label} 不应再包含 ONNX runtime entitlement(ONNX 应只在 helper 进程)"
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
    check_binary_archs "${mount_dir}/VowKy.app/Contents/Helpers/vowky-speechd" "DMG 内 vowky-speechd helper"
    check_helper_signature "${mount_dir}/VowKy.app/Contents/Helpers/vowky-transcribe" "DMG 内 vowky-transcribe helper"
    check_helper_signature "${mount_dir}/VowKy.app/Contents/Helpers/vowky-speechd" "DMG 内 vowky-speechd helper"
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
check_binary_archs "${SPEECH_HELPER_PATH}" "vowky-speechd helper"
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

# 始终带 Apple 安全时间戳签名（自更新的硬性要求，与「公证」解耦）。
#
# 为什么：安全时间戳(codesign --timestamp，走 Apple TSA timestamp.apple.com)与公证(notarytool)
# 是两件事。没有安全时间戳的签名(只有 Signed Time)拿不到 macOS Sequoia/Tahoe「App 管理」的
# 「同开发者自更新豁免」→ Sparkle 原地替换被系统拦 → 用户点更新报「更新错误」。
# 这是历史上「SKIP_NOTARIZE 测试版没法自更新」的真因，所以 SKIP_NOTARIZE 也必须带时间戳。
#
# 时间戳是轻量 TSA 调用，夜里也能成；万一 TSA 真不可达，默认硬失败(不让无时间戳的包出门)，
# 只有显式 ALLOW_NO_TIMESTAMP=1 才允许回退到 --timestamp=none(并醒目警告，仅供本地非更新测试)。
# 用法: codesign_timestamped <codesign 参数...>（不要自己带 --timestamp / --timestamp=none）
codesign_timestamped() {
    if codesign_with_retry --timestamp "$@"; then
        return 0
    fi
    if [ "${ALLOW_NO_TIMESTAMP:-}" = "1" ]; then
        log_warn "⚠️⚠️ Apple 时间戳服务器不可达——按 ALLOW_NO_TIMESTAMP=1 回退为【无安全时间戳】签名。"
        log_warn "⚠️⚠️ 此产物不能用于自更新测试或分发(macOS「App 管理」会拦截原地更新)。仅供本地非更新测试。"
        codesign --timestamp=none "$@"
        return $?
    fi
    log_error "Apple 时间戳服务器(timestamp.apple.com)不可达，无法生成可自更新的签名。"
    log_error "请检查网络/代理后重试；若确需无时间戳的本地测试包，用 ALLOW_NO_TIMESTAMP=1 重跑。"
    exit 1
}

# 自更新护栏：断言单个组件带有 Apple 安全时间戳(Timestamp=)，而非仅本地 Signed Time=。
# 缺时间戳会被 macOS「App 管理」拦截原地自更新(点更新报「更新错误」)，所以默认 exit 1，
# 不让这种包出门；ALLOW_NO_TIMESTAMP=1 时降级为警告(仅供本地非更新测试)。
assert_secure_timestamp() {
    local target="$1"; local label="${2:-$1}"
    # 用变量捕获 + bash 匹配，不要用 `| grep -q`：pipefail 下 grep -q 命中即关管道 →
    # codesign 收到 SIGPIPE 退非零 → 整条管道非零 → 即使有时间戳也被误判为「无」。
    # 给 $info 前置换行，使「行首 Timestamp=」无论在首行还是中间都能匹配。
    local info
    info="$(codesign -dvv "$target" 2>&1 || true)"
    if [[ $'\n'"$info" == *$'\n'"Timestamp="* ]]; then
        log_ok "  安全时间戳 ✓ ${label}"
        return 0
    fi
    if [ "${ALLOW_NO_TIMESTAMP:-}" = "1" ]; then
        log_warn "  安全时间戳 ✗ ${label}（仅 Signed Time）——ALLOW_NO_TIMESTAMP=1 放行；此包不可自更新。"
        return 0
    fi
    log_error "  安全时间戳 ✗ ${label}：缺少 Apple 可信时间戳(仅 Signed Time)。"
    log_error "  此包会被 macOS「App 管理」拦截原地自更新(用户点更新报「更新错误」)。中止构建。"
    exit 1
}

# 自更新护栏总入口：逐个校验主 app、两个 helper、Sparkle 全部内部组件都带安全时间戳。
verify_secure_timestamps_bundle() {
    log_info "校验安全时间戳(自更新必需)..."
    assert_secure_timestamp "${APP_PATH}" "VowKy.app"
    assert_secure_timestamp "${SPEECH_HELPER_PATH}" "vowky-speechd"
    assert_secure_timestamp "${HELPER_PATH}" "vowky-transcribe"
    # Sparkle 内部组件(与 sign_sparkle_internals 同一清单)
    while IFS= read -r item; do
        [ -e "$item" ] && assert_secure_timestamp "$item" "$(basename "$item")"
    done < <(find "${APP_PATH}/Contents/Frameworks" -name "*.xpc" -o -name "*.app" -o -name "Autoupdate")
    for fw in "${APP_PATH}/Contents/Frameworks/"*.framework; do
        [ -d "$fw" ] && assert_secure_timestamp "$fw" "$(basename "$fw")"
    done
    log_ok "全部组件均带安全时间戳"
}

sign_main_app() {
    # 主 app 必须带 entitlements；否则麦克风权限会被 TCC 静默拒绝。
    codesign_timestamped --force --sign "${SIGN_IDENTITY}" --options runtime --entitlements "${VOWKY_DIR}/VowKy/VowKy.entitlements" "${APP_PATH}"
}

sign_transcribe_helper() {
    # helper 不需要麦克风权限，只需要 ONNX runtime entitlement。
    codesign_timestamped --force --sign "${SIGN_IDENTITY}" --options runtime --entitlements "${VOWKY_DIR}/VowKyTranscribe.entitlements" "${HELPER_PATH}"
}

sign_speech_helper() {
    # 常驻语音 helper：只需要 ONNX runtime entitlement，不需要麦克风。
    codesign_timestamped --force --sign "${SIGN_IDENTITY}" --options runtime --entitlements "${VOWKY_DIR}/VowKySpeechHelper.entitlements" "${SPEECH_HELPER_PATH}"
}

sign_sparkle_internals() {
    # Sparkle 内嵌的 XPC 服务/辅助 app 必须带 Developer ID + matching team ID，
    # 否则 Sequoia/Tahoe 上进度代理(Updater.app)的 XPC 连接会因 team ID 不匹配失败。
    # 公证与非公证都要签、且都必须带安全时间戳(见 codesign_timestamped 注释)。
    # 1. 签名 Sparkle 内嵌的 XPC 服务和辅助 app
    find "${APP_PATH}/Contents/Frameworks" -name "*.xpc" -o -name "*.app" -o -name "Autoupdate" | sort -r | while read -r item; do
        [ -e "$item" ] && codesign_timestamped --force --sign "${SIGN_IDENTITY}" --options runtime "$item"
    done
    # 2. 签名 framework 顶层
    for fw in "${APP_PATH}/Contents/Frameworks/"*.framework; do
        [ -d "$fw" ] && codesign_timestamped --force --sign "${SIGN_IDENTITY}" --options runtime "$fw"
    done
}

# 由内到外签名：Sparkle 内部 → 两个 helper → 主 app。Sparkle 内部不再受 NOTARIZE 门控。
sign_sparkle_internals
sign_speech_helper
sign_transcribe_helper
sign_main_app
log_ok "代码签名完成"

# 自更新护栏：所有组件必须带 Apple 安全时间戳，否则原地自更新会被系统拦截。
verify_secure_timestamps_bundle

# 验证签名
check_helper_signature "${HELPER_PATH}" "vowky-transcribe helper"
check_helper_signature "${SPEECH_HELPER_PATH}" "vowky-speechd helper"
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
    sign_speech_helper
    sign_transcribe_helper
    sign_main_app
    xcrun stapler validate "${APP_PATH}"
    check_helper_signature "${HELPER_PATH}" "stapled vowky-transcribe helper"
    check_helper_signature "${SPEECH_HELPER_PATH}" "stapled vowky-speechd helper"
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
codesign_timestamped --force --sign "${SIGN_IDENTITY}" "${DMG_PATH}"
log_ok "DMG 签名完成"
# 自更新护栏：DMG 也必须带安全时间戳
assert_secure_timestamp "${DMG_PATH}" "DMG"

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
