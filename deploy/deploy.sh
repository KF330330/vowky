#!/bin/bash
# deploy/deploy.sh — VowKy 主部署入口
# 用法: ./deploy/deploy.sh
# 步骤: 构建 → 上传网站 → 上传 DMG → 生成 appcast.xml → 创建 GitHub Release

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
DMG_NAME="VowKy-${VERSION}.dmg"
DMG_PATH="${BUILD_DIR}/dmg/${DMG_NAME}"
RELEASE_NOTES_PATH="${VOWKY_DIR}/VowKy/Resources/ReleaseNotes/${VERSION}.md"

if [ ! -f "${DMG_PATH}" ]; then
    log_error "DMG 不存在: ${DMG_PATH}"
    exit 1
fi

# 版本说明强制要求存在且非空：appcast 与 GitHub Release 都需要它
if [ ! -f "${RELEASE_NOTES_PATH}" ]; then
    log_error "缺少版本说明文件: ${RELEASE_NOTES_PATH}"
    log_error "每个版本都必须有对应的 release notes（用户在 Sparkle 弹窗里能看到）"
    exit 1
fi
if [ ! -s "${RELEASE_NOTES_PATH}" ]; then
    log_error "版本说明文件为空: ${RELEASE_NOTES_PATH}"
    exit 1
fi
log_ok "Release notes: ${RELEASE_NOTES_PATH}"

# ============================================================
# 2. 上传网站（替换下载链接为带版本号的文件名）
# ============================================================
log_info "上传网站到 ${SERVER}:${WEB_ROOT}/site/..."
ssh "${SERVER}" "mkdir -p ${WEB_ROOT}/site ${WEB_ROOT}/downloads"

# 创建临时目录，替换下载链接后上传
SITE_STAGING="${BUILD_DIR}/site-staging"
rm -rf "${SITE_STAGING}"
cp -R "${WEBSITE_DIR}" "${SITE_STAGING}"
# 下载链接已改为指向 GitHub Releases，无需替换文件名

# 注入 Umami website-id（从 config.local.sh 读取）
if [ -n "${UMAMI_WEBSITE_ID:-}" ]; then
    sed -i '' "s|YOUR_WEBSITE_ID|${UMAMI_WEBSITE_ID}|g" "${SITE_STAGING}/index.html"
    log_ok "Umami website-id 已注入"
else
    log_warn "UMAMI_WEBSITE_ID 未设置，跳过注入"
fi

# --exclude appcast.xml：appcast 不属于网站源（在 step 5 单独上传）。
# 若被 --delete 误删，而后续步骤（如 GitHub 上传）中断没走到 step 5，
# 服务器 appcast 就会缺失 → 线上 /appcast.xml 404 → 所有用户自动更新全挂。
rsync -avz --delete --exclude='appcast.xml' \
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
DOWNLOAD_URL="https://github.com/KF330330/vowky/releases/download/v${VERSION}/${DMG_NAME}"
GITHUB_RELEASES_URL="https://github.com/KF330330/vowky/releases/latest"

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
    # 只提取 edSignature，length 已在模板中由 DMG_SIZE_BYTES 提供
    EDDSA_SIG=$(echo "$SPARKLE_SIGNATURE" | grep -o 'sparkle:edSignature="[^"]*"')
    EDDSA_ATTR=" ${EDDSA_SIG}"
fi

# 把 release notes 渲染成「清晰、暗色适配、带『新版本可更新』框定」的 HTML，嵌入 appcast description。
# Sparkle 更新弹窗的 WebView 直接渲染这段 HTML（弹窗标题栏/按钮是 Sparkle 自带，不可改）。
# 不依赖 pandoc：内置 awk 转换器对 release notes 的 markdown 子集（标题/列表/段落/链接/加粗）
# 确定性产出合规 HTML —— 杜绝旧版「没装 pandoc 就退化成 <pre> 等宽纯文本」的丑排版。

# .md 子集 → HTML 片段（剥掉冗余的「VowKy x.y 更新内容」首行，因为下面自带 <h1>）
md_to_html_fragment() {
    awk '
    function esc(s){ gsub(/&/,"\\&amp;",s); gsub(/</,"\\&lt;",s); gsub(/>/,"\\&gt;",s); return s }
    function inl(s,  out,rest,url,inner,m,tb,txt,prev){
        while (match(s,/\*\*[^*]+\*\*/)){ inner=substr(s,RSTART+2,RLENGTH-4); s=substr(s,1,RSTART-1) "<strong>" inner "</strong>" substr(s,RSTART+RLENGTH) }
        # markdown 链接 [text](url)
        out=""; rest=s
        while (match(rest,/\[[^]]+\]\([^)]+\)/)){ m=substr(rest,RSTART,RLENGTH); tb=index(m,"]("); txt=substr(m,2,tb-2); url=substr(m,tb+2,length(m)-tb-2); out=out substr(rest,1,RSTART-1) "<a href=\"" url "\">" txt "</a>"; rest=substr(rest,RSTART+RLENGTH) }
        s=out rest
        # 裸 URL（跳过已在 href="..." 里的）
        out=""; rest=s
        while (match(rest,/https?:\/\/[^ \t"<>]+/)){ url=substr(rest,RSTART,RLENGTH); prev=(RSTART>1)?substr(rest,RSTART-1,1):""; if(prev=="\""){ out=out substr(rest,1,RSTART-1+RLENGTH) } else { out=out substr(rest,1,RSTART-1) "<a href=\"" url "\">" url "</a>" } rest=substr(rest,RSTART+RLENGTH) }
        return out rest
    }
    BEGIN{ inlist=0; started=0 }
    {
        line=$0
        if(!started && line ~ /^#{0,3}[ ]*VowKy /){ next }   # 剥掉首行标题
        if(!started && line ~ /^[ \t]*$/){ next }             # 跳过开头空行
        started=1
        if(line ~ /^[ \t]*$/){ if(inlist){print "</ul>"; inlist=0} next }
        if(line ~ /^[ \t]*[-*] /){ sub(/^[ \t]*[-*] /,"",line); if(!inlist){print "<ul>"; inlist=1} print "<li>" inl(esc(line)) "</li>"; next }
        if(inlist){print "</ul>"; inlist=0}
        if(line ~ /^### /){ sub(/^### /,"",line); print "<h3>" inl(esc(line)) "</h3>"; next }
        if(line ~ /^#{1,2} /){ sub(/^#{1,2} /,"",line); print "<h2>" inl(esc(line)) "</h2>"; next }
        print "<p>" inl(esc(line)) "</p>"
    }
    END{ if(inlist) print "</ul>" }
    ' "$1"
}

build_release_notes_html() {
    local md="$1" version="$2" body
    body="$(md_to_html_fragment "$md")"
    cat <<HTMLDOC
<style>
:root{color-scheme:light dark}
body{font-family:-apple-system,"PingFang SC",sans-serif;margin:18px 20px;line-height:1.6;color:#1d1d1f;-webkit-font-smoothing:antialiased}
.tag{display:inline-block;font-size:11px;font-weight:600;color:#fff;background:#34c759;border-radius:5px;padding:2px 8px;letter-spacing:.3px}
h1{font-size:18px;font-weight:700;margin:10px 0 2px}
h2{font-size:15px;font-weight:600;margin:16px 0 6px}
h3{font-size:13px;font-weight:600;margin:12px 0 4px}
.sub{font-size:12px;color:#86868b;margin:0 0 14px}
ul{padding-left:1.15em;margin:0}
li{font-size:13px;margin:0 0 9px}
p{font-size:13px;margin:0 0 10px}
a{color:#0a84ff;text-decoration:none}
@media (prefers-color-scheme:dark){body{color:#f5f5f7}.sub{color:#98989d}}
</style>
<span class="tag">新版本可更新</span>
<h1>🦋 VowKy ${version} 已发布</h1>
<p class="sub">点下方「安装更新」即可升级到最新版</p>
${body}
HTMLDOC
}

RELEASE_NOTES_CONTENT="$(build_release_notes_html "${RELEASE_NOTES_PATH}" "${VERSION}")"
log_info "release notes 已生成样式化 HTML（内置渲染，无需 pandoc）"

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
      <description><![CDATA[
${RELEASE_NOTES_CONTENT}
]]></description>
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
# 6. 创建 GitHub Release（DMG 经服务器中转上传）
# ============================================================
# 本机→GitHub 直传 268MB DMG 跨境极易超时（历史上多次中断，留下空 Release）。
# DMG 已在 step 3 传到服务器，这里只在本机创建 Release 元数据（极小），
# 大文件改由服务器侧 curl 直传 GitHub（server→GitHub 带宽稳定，实测 ~11MB/s）。
log_info "创建 GitHub Release v${VERSION}..."
GH_REPO="KF330330/vowky"

if gh release view "v${VERSION}" &>/dev/null; then
    log_warn "Release v${VERSION} 已存在，复用并覆盖 DMG asset"
else
    gh release create "v${VERSION}" \
        --title "VowKy ${VERSION}" \
        --notes-file "${RELEASE_NOTES_PATH}" \
        --latest
fi

RELEASE_ID="$(gh api "repos/${GH_REPO}/releases/tags/v${VERSION}" --jq '.id')"

# 删除同名旧 asset（模拟 --clobber，避免重传时 422 already_exists）
for asset_name in "${DMG_NAME}" "VowKy.dmg"; do
    asset_id="$(gh api "repos/${GH_REPO}/releases/${RELEASE_ID}/assets" \
        --jq ".[] | select(.name==\"${asset_name}\") | .id" 2>/dev/null | head -1)"
    if [ -n "${asset_id}" ]; then
        gh api -X DELETE "repos/${GH_REPO}/releases/assets/${asset_id}" >/dev/null 2>&1 || true
    fi
done

# 经服务器中转上传：本机只传非密的注入值作为远端环境变量，token 同样注入；
# 远端脚本用 'EOF'（单引号）heredoc，所有 ${..} 在远端展开，避免本机/远端引号混淆。
# 同时上传带版本号 + 不带版本号两个名字（后者支撑 /releases/latest/download/VowKy.dmg）。
log_info "经服务器中转上传 DMG 到 GitHub Release..."
GH_TOKEN_VAL="$(gh auth token)"
ssh "${SERVER}" \
    "GH_TOKEN_VAL='${GH_TOKEN_VAL}' GH_REPO='${GH_REPO}' RELEASE_ID='${RELEASE_ID}' DMG_NAME='${DMG_NAME}' WEB_ROOT='${WEB_ROOT}' bash -s" <<'REMOTE_UPLOAD'
set -e
cd "${WEB_ROOT}/downloads"
for upload_name in "${DMG_NAME}" "VowKy.dmg"; do
    curl -fsS -X POST \
        -H "Authorization: token ${GH_TOKEN_VAL}" \
        -H "Content-Type: application/octet-stream" \
        -T "${DMG_NAME}" \
        "https://uploads.github.com/repos/${GH_REPO}/releases/${RELEASE_ID}/assets?name=${upload_name}" >/dev/null
done
REMOTE_UPLOAD

# 确保该版本为 latest（两个 tag 指向同一 commit 时 GitHub 的 latest 判定会有歧义）
gh release edit "v${VERSION}" --latest >/dev/null

# 校验两个 asset 均已就绪——服务器中转上传若某个 asset 静默漏传，这里会拦下。
# 注意：GitHub 上传完成后 API/CDN 同步有数十秒延迟，立即查可能误判缺失，故带重试。
log_info "校验 Release assets（含同步延迟重试）..."
for verify_name in "${DMG_NAME}" "VowKy.dmg"; do
    asset_ok=false
    for _attempt in 1 2 3 4 5 6; do
        asset_state="$(gh api "repos/${GH_REPO}/releases/${RELEASE_ID}/assets" \
            --jq ".[] | select(.name==\"${verify_name}\") | .state" 2>/dev/null | head -1)"
        if [ "${asset_state}" = "uploaded" ]; then asset_ok=true; break; fi
        sleep 10
    done
    if [ "${asset_ok}" = true ]; then
        log_ok "asset 就绪: ${verify_name}"
    else
        log_error "asset 缺失或未就绪: ${verify_name} (state='${asset_state:-none}')，请手动补传后再发布"
        exit 1
    fi
done
log_ok "GitHub Release 完成（DMG 经服务器中转）"

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
echo "  下载:     ${GITHUB_RELEASES_URL}"
echo "  Appcast:  https://${DOMAIN}/appcast.xml"
echo "============================================"
