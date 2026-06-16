#!/bin/bash
# deploy/preflight.sh — 部署前环境预检
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

PASS=0
FAIL=0
WARN=0

check_pass() { ((PASS++)); echo "  ✓ $1"; }
check_fail() { ((FAIL++)); echo "  ✗ $1"; }
check_warn() { ((WARN++)); echo "  ⚠ $1"; }

echo "VowKy 部署预检"
echo "============================================"

# 1. config.local.sh
echo ""
echo "[1/8] 检查本地配置..."
if [ -f "${SCRIPT_DIR}/config.local.sh" ]; then
    check_pass "config.local.sh 存在"
else
    check_fail "config.local.sh 不存在，请从 config.local.sh.example 复制并配置"
fi

# 2. SSH 连接
echo ""
echo "[2/8] 检查 SSH 连接..."
if ssh -o ConnectTimeout=5 -o BatchMode=yes "${SERVER}" "echo ok" &>/dev/null; then
    check_pass "SSH 连接到 ${SERVER} 成功"
else
    check_fail "SSH 连接到 ${SERVER} 失败"
fi

# 3. 代码签名证书
echo ""
echo "[3/8] 检查代码签名证书..."
if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    check_pass "Developer ID Application 证书可用"
else
    check_fail "未找到 Developer ID Application 证书"
fi

# 4. xcodegen
echo ""
echo "[4/8] 检查 xcodegen..."
if command -v xcodegen &>/dev/null; then
    check_pass "xcodegen 已安装 ($(xcodegen --version 2>/dev/null || echo 'unknown'))"
else
    check_fail "xcodegen 未安装 (brew install xcodegen)"
fi

# 5. 服务器 Nginx
echo ""
echo "[5/8] 检查服务器 Nginx..."
if ssh -o ConnectTimeout=5 "${SERVER}" "systemctl is-active nginx" &>/dev/null; then
    check_pass "Nginx 运行中"
else
    check_warn "无法确认 Nginx 状态"
fi

# 6. 磁盘空间
echo ""
echo "[6/8] 检查磁盘空间..."
AVAIL_GB=$(df -g / | awk 'NR==2{print $4}')
if [ "${AVAIL_GB}" -ge 5 ]; then
    check_pass "可用空间 ${AVAIL_GB}GB (≥5GB)"
else
    check_fail "可用空间 ${AVAIL_GB}GB (<5GB)"
fi

# 7. Release notes（中英双语：{ver}.md=中文，{ver}.en.md=英文）
echo ""
echo "[7/8] 检查当前版本 release notes（中英双语）..."
VERSION_FOR_CHECK="$(get_version)"
RN_DIR_CHECK="${VOWKY_DIR}/VowKy/Resources/ReleaseNotes"
for rn_pair in "${VERSION_FOR_CHECK}.md|中文" "${VERSION_FOR_CHECK}.en.md|英文"; do
    rn_name="${rn_pair%%|*}"
    rn_label="${rn_pair##*|}"
    rn_file="${RN_DIR_CHECK}/${rn_name}"
    if [ ! -f "${rn_file}" ]; then
        check_fail "缺少${rn_label} release notes: ${rn_file}"
    elif [ ! -s "${rn_file}" ]; then
        check_fail "${rn_label} release notes 为空: ${rn_file}"
    else
        check_pass "${rn_label} release notes 已就绪 (${rn_name})"
    fi
done

# 8. Sparkle sign_update
echo ""
echo "[8/8] 检查 Sparkle 工具..."
if command -v sign_update &>/dev/null || [ -x "/usr/local/bin/sign_update" ] || [ -x "${HOME}/Library/Developer/Sparkle/bin/sign_update" ]; then
    check_pass "sign_update 可用"
else
    check_warn "sign_update 未找到，自动更新签名将跳过 (brew install sparkle)"
fi

# 汇总
echo ""
echo "============================================"
echo "  结果: ✓ ${PASS} 通过  ✗ ${FAIL} 失败  ⚠ ${WARN} 警告"
echo "============================================"

if [ "${FAIL}" -gt 0 ]; then
    echo "  存在失败项，请修复后再部署"
    exit 1
fi
