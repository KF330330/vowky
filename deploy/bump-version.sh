#!/bin/bash
# deploy/bump-version.sh — VowKy 版本管理
# 用法: ./deploy/bump-version.sh [patch|minor|major|build|x.y.z]
#
# 示例:
#   ./deploy/bump-version.sh patch    # 1.0.0 → 1.0.1, build +1
#   ./deploy/bump-version.sh minor    # 1.0.1 → 1.1.0, build +1
#   ./deploy/bump-version.sh major    # 1.1.0 → 2.0.0, build +1
#   ./deploy/bump-version.sh build    # 版本号不变, build +1
#   ./deploy/bump-version.sh 2.1.0   # 直接设为 2.1.0, build +1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# ============================================================
# 参数解析
# ============================================================
ACTION="${1:-}"

if [ -z "$ACTION" ]; then
    echo "用法: $0 [patch|minor|major|build|x.y.z]"
    echo ""
    echo "  patch   — 补丁版本 +1 (x.y.Z)"
    echo "  minor   — 次版本 +1, 补丁归零 (x.Y.0)"
    echo "  major   — 主版本 +1, 次版本和补丁归零 (X.0.0)"
    echo "  build   — 仅 build number +1"
    echo "  x.y.z   — 直接设为指定版本号"
    exit 1
fi

# ============================================================
# 读取当前版本
# ============================================================
CURRENT_VERSION="$(get_version)"
CURRENT_BUILD="$(get_build)"

log_info "当前版本: ${CURRENT_VERSION} (${CURRENT_BUILD})"

# ============================================================
# 解析版本号为三段 (补齐缺失段)
# ============================================================
parse_version() {
    local ver="$1"
    IFS='.' read -r -a parts <<< "$ver"
    MAJOR="${parts[0]:-0}"
    MINOR="${parts[1]:-0}"
    PATCH="${parts[2]:-0}"
}

parse_version "$CURRENT_VERSION"

# ============================================================
# 计算新版本
# ============================================================
case "$ACTION" in
    patch)
        PATCH=$((PATCH + 1))
        NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
        ;;
    minor)
        MINOR=$((MINOR + 1))
        PATCH=0
        NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
        ;;
    major)
        MAJOR=$((MAJOR + 1))
        MINOR=0
        PATCH=0
        NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
        ;;
    build)
        NEW_VERSION="${CURRENT_VERSION}"
        ;;
    *)
        # 校验 x.y.z 格式
        if [[ "$ACTION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
            NEW_VERSION="$ACTION"
        else
            log_error "无效参数: $ACTION"
            echo "用法: $0 [patch|minor|major|build|x.y.z]"
            exit 1
        fi
        ;;
esac

# build number 始终 +1
NEW_BUILD=$((CURRENT_BUILD + 1))

# ============================================================
# 写入 Info.plist
# ============================================================
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${NEW_VERSION}" "$INFOPLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${NEW_BUILD}" "$INFOPLIST"

log_ok "版本已更新: ${CURRENT_VERSION} (${CURRENT_BUILD}) → ${NEW_VERSION} (${NEW_BUILD})"
echo ""
echo "  CFBundleShortVersionString: ${NEW_VERSION}"
echo "  CFBundleVersion:            ${NEW_BUILD}"
echo "  文件: ${INFOPLIST}"

# ============================================================
# Release notes stub
# deploy.sh / preflight.sh 都强制要求 {NEW_VERSION}.md 存在且非空，
# 这里 bump 完顺手生成 stub，避免用户漏写 → 等到 preflight 才报错。
# ============================================================
RELEASE_NOTES_DIR="${VOWKY_DIR}/VowKy/Resources/ReleaseNotes"
ZH_NOTES_PATH="${RELEASE_NOTES_DIR}/${NEW_VERSION}.md"       # 中文（默认文件名）
EN_NOTES_PATH="${RELEASE_NOTES_DIR}/${NEW_VERSION}.en.md"    # 英文（.en.md 后缀）

mkdir -p "${RELEASE_NOTES_DIR}"

echo ""
if [ -f "${ZH_NOTES_PATH}" ]; then
    log_info "release notes（中文）已存在，未覆盖：${ZH_NOTES_PATH}"
else
    cat > "${ZH_NOTES_PATH}" <<EOF
VowKy ${NEW_VERSION} 更新内容

- TODO：在此填写本次更新的用户可见变化（3-6 条要点）

如有问题，欢迎到 https://github.com/KF330330/vowky/issues 反馈。
EOF
    log_warn "已生成中文 release notes stub：${ZH_NOTES_PATH}"
fi

if [ -f "${EN_NOTES_PATH}" ]; then
    log_info "release notes（英文）已存在，未覆盖：${EN_NOTES_PATH}"
else
    cat > "${EN_NOTES_PATH}" <<EOF
VowKy ${NEW_VERSION} Release Notes

- TODO: describe the user-visible changes in this release (3-6 bullet points)

Questions or feedback? Visit https://github.com/KF330330/vowky/issues
EOF
    log_warn "已生成英文 release notes stub：${EN_NOTES_PATH}"
fi
log_warn "请编辑以上中英文 release notes 填写本次更新内容（deploy/preflight 会校验两者非空）"
