#!/bin/bash
# deploy/mirror-tools.sh — 同步 yt-dlp / ffmpeg / deno 到 vowky.com 工具镜像（App 优先镜像、失败回上游）
#
# 目录：${WEB_ROOT}/downloads/tools/
#   manifest.signed.json                       ← 唯一清单入口（签名信封，原子替换）
#   README.md  LICENSES/{GPL-3.0.txt,V8-LICENSE.txt}   ← 入口文档（每次覆盖）
#   yt-dlp/<tag>/{yt-dlp_macos,SHA2-256SUMS,yt-dlp-<tag>.tar.gz,LICENSE,build.yml,COMPONENTS.txt}   ← 不可变
#   ffmpeg/<buildId>/ffmpeg-<version>.tar.xz                                                        ← 不可变
#   ffmpeg/<buildId>/<arch>/{ffmpeg.zip,ffmpeg.zip.sha256,versions.txt,detail.html}                 ← 不可变
#   deno/<tag>/<arch>/deno-<triple>-apple-darwin.zip                                                ← 不可变
#   deno/<tag>/<arch>/deno-<triple>-apple-darwin.zip.sha256sum                                      ← 不可变
#   deno/<tag>/<arch>/deno-<triple>-apple-darwin.sha256sum                                          ← 不可变
#   deno/<tag>/{LICENSE.md,Cargo.lock}                                                              ← 不可变
#
# 环境变量：
#   YTDLP_TAG=<tag>                    钉 yt-dlp 版本（默认取 GitHub latest）
#   FFMPEG_BUILD_ID_ARM64=<buildId>    钉 arm64 ffmpeg 构建（默认跟随 martin-riedl latest 重定向）
#   FFMPEG_BUILD_ID_AMD64=<buildId>    钉 amd64 ffmpeg 构建
#   DENO_TAG=<tag>                     钉 deno 版本（默认取 GitHub latest）
#                                      deno 资产优先取 dl.deno.land（官方 CDN），GitHub release 回退
#   MIRROR_ABORT_BEFORE_MANIFEST=1     在发布签名信封前退出（验收原子性用，exit 3）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
TOOLS_REMOTE="${WEB_ROOT}/downloads/tools"
TOOLS_URL_BASE="https://${DOMAIN}/downloads/tools"

# ------------------------------------------------------------
# 小工具
# ------------------------------------------------------------

# 上游站点（尤其 ffmpeg.martin-riedl.de）在本机网络下会间歇性 RST 连接，
# 且大文件下完之后紧接着的小请求最容易被打断。因此退避阶梯拉长到分钟级，
# 大文件用 .part + `-C -` 断点续传，避免每次重试都从头再拉几十 MB。
RETRY_DELAYS="5 10 20 30 45 60 90 120"
RETRY_MAX=9

_retry_delay_for() {
    local attempt="$1" delay
    delay="$(echo "$RETRY_DELAYS" | awk -v i="$attempt" '{print $i}')"
    [[ -n "$delay" ]] || delay=120
    echo "$delay"
}

# 下载核心：带退避重试 + 断点续传，成功返回 0、失败返回 1（**不退出**，由调用方决定致命与否）。
# 用法: _fetch_core <url> <dest> <max_attempts>
_fetch_core() {
    local url="$1" dest="$2" max="$3" part attempt rc delay
    mkdir -p "$(dirname "$dest")"
    part="${dest}.part"
    rm -f "$part"

    for attempt in $(seq 1 "$max"); do
        rc=0
        if [[ "$attempt" -gt 1 && -s "$part" ]]; then
            curl -fsSL -C - --connect-timeout 20 --max-time 1800 -A "$UA" -o "$part" "$url" || rc=$?
        else
            rm -f "$part"
            curl -fsSL --connect-timeout 20 --max-time 1800 -A "$UA" -o "$part" "$url" || rc=$?
        fi

        if [[ "$rc" -eq 0 ]]; then
            mv -f "$part" "$dest"
            return 0
        fi

        # 22=HTTP 错误（含续传被拒的 416）、33/36=服务端不支持续传/续传点非法 → 丢弃半成品重来
        if [[ "$rc" -eq 22 || "$rc" -eq 33 || "$rc" -eq 36 ]]; then
            rm -f "$part"
        fi

        if [[ "$attempt" -lt "$max" ]]; then
            delay="$(_retry_delay_for "$attempt")"
            log_warn "下载第 ${attempt}/${max} 次失败 (curl ${rc})，${delay}s 后重试: ${url}"
            sleep "$delay"
        fi
    done

    rm -f "$part"
    return 1
}

# 必成的下载：失败即中止整条发布。用法: fetch <url> <dest>
fetch() {
    if ! _fetch_core "$1" "$2" "$RETRY_MAX"; then
        log_error "下载失败（已重试 ${RETRY_MAX} 次）: $1"
        exit 1
    fi
}

# 允许失败的下载（供多来源回退链使用），默认只试 3 次以免拖长回退。
# 用法: fetch_optional <url> <dest> [max_attempts]
fetch_optional() {
    _fetch_core "$1" "$2" "${3:-3}"
}

# 带退避重试、把响应体打到 stdout 的 GET。失败返回非 0（由调用方决定是否致命）。
fetch_stdout() {
    local url="$1" attempt delay
    for attempt in $(seq 1 "$RETRY_MAX"); do
        if curl -fsSL --connect-timeout 20 --max-time 300 -A "$UA" "$url"; then
            return 0
        fi
        if [[ "$attempt" -lt "$RETRY_MAX" ]]; then
            delay="$(_retry_delay_for "$attempt")"
            log_warn "请求第 ${attempt}/${RETRY_MAX} 次失败，${delay}s 后重试: ${url}" >&2
            sleep "$delay"
        fi
    done
    return 1
}

# 带退避重试的「跟随重定向取最终 URL」。失败返回非 0。
fetch_effective_url() {
    local url="$1" attempt delay effective
    for attempt in $(seq 1 "$RETRY_MAX"); do
        if effective="$(curl -fsSIL --connect-timeout 20 --max-time 120 -A "$UA" \
                             -o /dev/null -w '%{url_effective}' "$url")" && [[ -n "$effective" ]]; then
            echo "$effective"
            return 0
        fi
        if [[ "$attempt" -lt "$RETRY_MAX" ]]; then
            delay="$(_retry_delay_for "$attempt")"
            log_warn "解析重定向第 ${attempt}/${RETRY_MAX} 次失败，${delay}s 后重试: ${url}" >&2
            sleep "$delay"
        fi
    done
    return 1
}

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
size_of()   { wc -c < "$1" | tr -d ' '; }

# ============================================================
# 1. 准备暂存目录 + 定位 sign_update
# ============================================================
log_info "[1/12] 准备暂存目录与签名工具"

STAGE="${BUILD_DIR}/tools-mirror"
rm -rf "$STAGE"
mkdir -p "$STAGE"

SIGN_UPDATE=""
for candidate in \
    "$(command -v sign_update 2>/dev/null || true)" \
    "/usr/local/bin/sign_update" \
    "${HOME}/Library/Developer/Sparkle/bin/sign_update" \
    "$(ls "${HOME}"/Library/Developer/Xcode/DerivedData/VowKy-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update 2>/dev/null | head -1)"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
        SIGN_UPDATE="$candidate"
        break
    fi
done
if [[ -z "$SIGN_UPDATE" ]]; then
    log_error "未找到 sign_update，无法为镜像清单签名"
    exit 1
fi
log_ok "sign_update: ${SIGN_UPDATE}"
log_ok "暂存目录: ${STAGE}"

# ============================================================
# 2. yt-dlp：二进制 + 校验 + 源码 + 许可证 + 构建配置 + 组件对应表
# ============================================================
log_info "[2/12] 抓取 yt-dlp"

if [[ -n "${YTDLP_TAG:-}" ]]; then
    TAG="$YTDLP_TAG"
    log_info "使用钉住的 yt-dlp tag: ${TAG}"
else
    TAG="$(fetch_stdout 'https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest' \
           | python3 -c 'import sys,json;print(json.load(sys.stdin)["tag_name"])' || true)"
    if [[ -z "$TAG" ]]; then
        log_error "无法获取 yt-dlp 最新 tag"
        exit 1
    fi
    log_info "yt-dlp 最新 tag: ${TAG}"
fi

YTDLP_DIR="${STAGE}/yt-dlp/${TAG}"
mkdir -p "$YTDLP_DIR"

fetch "https://github.com/yt-dlp/yt-dlp/releases/download/${TAG}/yt-dlp_macos" "${YTDLP_DIR}/yt-dlp_macos"
fetch "https://github.com/yt-dlp/yt-dlp/releases/download/${TAG}/SHA2-256SUMS"  "${YTDLP_DIR}/SHA2-256SUMS"

YTDLP_EXPECTED_SHA="$(awk '$2 == "yt-dlp_macos" {print $1}' "${YTDLP_DIR}/SHA2-256SUMS" | head -1)"
YTDLP_SHA="$(sha256_of "${YTDLP_DIR}/yt-dlp_macos")"
if [[ -z "$YTDLP_EXPECTED_SHA" ]]; then
    log_error "SHA2-256SUMS 中找不到 yt-dlp_macos 条目"
    exit 1
fi
if [[ "$YTDLP_EXPECTED_SHA" != "$YTDLP_SHA" ]]; then
    log_error "yt-dlp_macos 校验不匹配: 期望 ${YTDLP_EXPECTED_SHA}，实得 ${YTDLP_SHA}"
    exit 1
fi
YTDLP_SIZE="$(size_of "${YTDLP_DIR}/yt-dlp_macos")"
log_ok "yt-dlp_macos 校验通过 (${YTDLP_SIZE} bytes)"

fetch "https://github.com/yt-dlp/yt-dlp/archive/refs/tags/${TAG}.tar.gz" "${YTDLP_DIR}/yt-dlp-${TAG}.tar.gz"
fetch "https://raw.githubusercontent.com/yt-dlp/yt-dlp/${TAG}/LICENSE"   "${YTDLP_DIR}/LICENSE"
fetch "https://raw.githubusercontent.com/yt-dlp/yt-dlp/${TAG}/.github/workflows/build.yml" "${YTDLP_DIR}/build.yml"
log_ok "yt-dlp 源码包 / LICENSE / build.yml 已就位"

# --- 组件对应表：由二进制自报 ---
chmod +x "${YTDLP_DIR}/yt-dlp_macos"
YTDLP_DEBUG_RAW="$("${YTDLP_DIR}/yt-dlp_macos" -v --ignore-config --no-update --simulate https://example.invalid/x 2>&1 \
                   | grep -E '^\[debug\] (yt-dlp version|Python|Optional libraries)' || true)"
if [[ -z "$YTDLP_DEBUG_RAW" ]]; then
    log_error "yt-dlp_macos 未能自报版本/组件信息，无法生成 COMPONENTS.txt"
    exit 1
fi

YTDLP_DEBUG_RAW="$YTDLP_DEBUG_RAW" YTDLP_TAG_OUT="$TAG" \
python3 - "${YTDLP_DIR}/COMPONENTS.txt" <<'PY'
import datetime
import os
import re
import sys

out_path = sys.argv[1]
raw = os.environ["YTDLP_DEBUG_RAW"]
tag = os.environ["YTDLP_TAG_OUT"]

# PyPI 分发名与 yt-dlp 自报的 import 名不一致的几个库
PYPI_MAP = {
    "Cryptodome": "pycryptodomex",
    "yt_dlp_ejs": "yt-dlp-ejs",
    "curl_cffi": "curl-cffi",
}
STDLIB = {"sqlite3"}

commit = ""
ytdlp_version = tag
python_version = ""
libraries = []

for line in raw.splitlines():
    line = line.strip()
    m = re.match(r"^\[debug\] yt-dlp version \S*?@?([0-9][^\s]*) from \S+ \[([0-9a-f]+)\]", line)
    if m:
        ytdlp_version, commit = m.group(1), m.group(2)
        continue
    m = re.match(r"^\[debug\] Python ([0-9][0-9A-Za-z.+-]*)", line)
    if m:
        python_version = m.group(1)
        continue
    m = re.match(r"^\[debug\] Optional libraries:\s*(.+)$", line)
    if m:
        for item in m.group(1).split(","):
            item = item.strip()
            if not item or item.lower() == "none":
                continue
            if "-" not in item:
                libraries.append((item, ""))
                continue
            name, version = item.rsplit("-", 1)
            libraries.append((name, version))

if not python_version:
    sys.stderr.write("未能从二进制自报中解析出 Python 版本\n")
    raise SystemExit(1)

rows = []
if commit:
    rows.append(
        "- yt-dlp %s (commit %s) -> ./yt-dlp-%s.tar.gz  |  https://github.com/yt-dlp/yt-dlp/tree/%s"
        % (ytdlp_version, commit, tag, commit)
    )
else:
    rows.append("- yt-dlp %s -> ./yt-dlp-%s.tar.gz" % (ytdlp_version, tag))

rows.append(
    "- Python %s -> https://www.python.org/ftp/python/%s/Python-%s.tgz"
    % (python_version, python_version, python_version)
)

for name, version in libraries:
    if name in STDLIB:
        rows.append(
            "- %s %s -> Python 标准库，源码含于上面的 Python-%s.tgz"
            % (name, version, python_version)
        )
        continue
    pypi = PYPI_MAP.get(name, name)
    if version:
        rows.append(
            "- %s %s (PyPI: %s) -> https://pypi.org/project/%s/%s/#files"
            % (name, version, pypi, pypi, version)
        )
    else:
        rows.append("- %s (PyPI: %s) -> https://pypi.org/project/%s/#files" % (name, pypi, pypi))

generated = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

lines = []
lines.append("yt-dlp %s — PyInstaller 打包发行物「组件 → 精确版本 → 对应源码」对应表" % tag)
lines.append("生成时间: %s" % generated)
lines.append("")
lines.append("本目录的 yt-dlp_macos 是 yt-dlp 官方 GitHub Release 的原始二进制（逐字节未修改），")
lines.append("由 PyInstaller 把 Python 解释器与下列库打包在一起。整体按 GPLv3+ 分发。")
lines.append("下表由该二进制自身的 `-v` 输出生成，因此版本与本目录二进制严格对应。")
lines.append("")
lines.append("== 二进制自报原文 ==")
for line in raw.splitlines():
    lines.append(line.rstrip())
lines.append("")
lines.append("== 组件 → 精确版本 → 对应源码 ==")
lines.extend(rows)
lines.append("")
lines.append("== 构建配置 ==")
lines.append("PyInstaller 打包工作流: ./build.yml")
lines.append("yt-dlp 自身源码: ./yt-dlp-%s.tar.gz" % tag)
lines.append("许可证全文: ./LICENSE（另见镜像根目录 LICENSES/GPL-3.0.txt）")
lines.append("")

with open(out_path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines))
PY

COMPONENT_ROWS="$(grep -c '^- ' "${YTDLP_DIR}/COMPONENTS.txt" || true)"
if [[ -z "$COMPONENT_ROWS" || "$COMPONENT_ROWS" -lt 8 ]]; then
    log_error "COMPONENTS.txt 组件行只有 ${COMPONENT_ROWS} 条（要求 ≥8），生成失败"
    exit 1
fi
log_ok "COMPONENTS.txt 已生成（${COMPONENT_ROWS} 条组件对应关系）"

# ============================================================
# 3. ffmpeg：两个架构的二进制 + 校验 + 组件版本清单 + 详情页快照 + 源码
# ============================================================
log_info "[3/12] 抓取 ffmpeg (arm64 / amd64)"

FFMPEG_SRC_CACHE=""
for ARCH in arm64 amd64; do
    ARCH_UPPER="$(echo "$ARCH" | tr '[:lower:]' '[:upper:]')"
    eval "PINNED_ID=\${FFMPEG_BUILD_ID_${ARCH_UPPER}:-}"

    if [[ -n "$PINNED_ID" ]]; then
        BUILD_ID="$PINNED_ID"
        log_info "使用钉住的 ffmpeg buildId (${ARCH}): ${BUILD_ID}"
    else
        if ! EFFECTIVE_URL="$(fetch_effective_url "https://ffmpeg.martin-riedl.de/redirect/latest/macos/${ARCH}/release/ffmpeg.zip")"; then
            log_error "无法解析 ffmpeg latest 重定向 (${ARCH})"
            exit 1
        fi
        BUILD_ID="$(basename "$(dirname "$EFFECTIVE_URL")")"
        if [[ -z "$BUILD_ID" || "$BUILD_ID" == "." || "$BUILD_ID" != *_* ]]; then
            log_error "无法从重定向解析 ffmpeg buildId (${ARCH}): ${EFFECTIVE_URL}"
            exit 1
        fi
        log_info "ffmpeg ${ARCH} 最新 buildId: ${BUILD_ID}"
    fi

    FFVERSION="${BUILD_ID#*_}"
    BASE="https://ffmpeg.martin-riedl.de/download/macos/${ARCH}/${BUILD_ID}"
    ARCH_DIR="${STAGE}/ffmpeg/${BUILD_ID}/${ARCH}"
    mkdir -p "$ARCH_DIR"

    fetch "${BASE}/ffmpeg.zip"        "${ARCH_DIR}/ffmpeg.zip"
    fetch "${BASE}/ffmpeg.zip.sha256" "${ARCH_DIR}/ffmpeg.zip.sha256"

    FF_EXPECTED_SHA="$(awk '{print $1}' "${ARCH_DIR}/ffmpeg.zip.sha256" | head -1)"
    FF_SHA="$(sha256_of "${ARCH_DIR}/ffmpeg.zip")"
    if [[ -z "$FF_EXPECTED_SHA" ]]; then
        log_error "ffmpeg.zip.sha256 (${ARCH}) 为空"
        exit 1
    fi
    if [[ "$FF_EXPECTED_SHA" != "$FF_SHA" ]]; then
        log_error "ffmpeg.zip (${ARCH}) 校验不匹配: 期望 ${FF_EXPECTED_SHA}，实得 ${FF_SHA}"
        exit 1
    fi
    FF_SIZE="$(size_of "${ARCH_DIR}/ffmpeg.zip")"
    log_ok "ffmpeg.zip (${ARCH}) 校验通过 (${FF_SIZE} bytes)"

    fetch "${BASE}/versions.txt" "${ARCH_DIR}/versions.txt"
    if [[ ! -s "${ARCH_DIR}/versions.txt" ]] || ! grep -qi 'ffmpeg' "${ARCH_DIR}/versions.txt"; then
        log_error "versions.txt (${ARCH}) 为空或不含 ffmpeg 字样，合规材料不完整"
        exit 1
    fi

    fetch "https://ffmpeg.martin-riedl.de/info/detail/macos/${ARCH}/${BUILD_ID}" "${ARCH_DIR}/detail.html"

    # ffmpeg 自身源码包（同一 version 只下载一次，另一 arch 直接复制）
    SRC_DEST="${STAGE}/ffmpeg/${BUILD_ID}/ffmpeg-${FFVERSION}.tar.xz"
    if [[ -f "$SRC_DEST" ]]; then
        log_info "ffmpeg-${FFVERSION}.tar.xz 已存在，跳过"
    elif [[ -n "$FFMPEG_SRC_CACHE" && -f "$FFMPEG_SRC_CACHE" && "$(basename "$FFMPEG_SRC_CACHE")" == "ffmpeg-${FFVERSION}.tar.xz" ]]; then
        cp "$FFMPEG_SRC_CACHE" "$SRC_DEST"
        log_info "ffmpeg-${FFVERSION}.tar.xz 复用本次已下载副本"
    else
        fetch "https://ffmpeg.org/releases/ffmpeg-${FFVERSION}.tar.xz" "$SRC_DEST"
        FFMPEG_SRC_CACHE="$SRC_DEST"
    fi

    BUILD_EPOCH="${BUILD_ID%%_*}"
    if [[ "$BUILD_EPOCH" =~ ^[0-9]+$ ]]; then
        BUILD_TIME="$(date -u -r "$BUILD_EPOCH" +"%Y-%m-%d %H:%M:%S UTC")"
    else
        BUILD_TIME="未知"
    fi

    eval "BUILD_ID_${ARCH}=\"\$BUILD_ID\""
    eval "FFVERSION_${ARCH}=\"\$FFVERSION\""
    eval "FFSHA_${ARCH}=\"\$FF_SHA\""
    eval "FFSIZE_${ARCH}=\"\$FF_SIZE\""
    eval "BUILDTIME_${ARCH}=\"\$BUILD_TIME\""
done

if [[ "$FFVERSION_arm64" != "$FFVERSION_amd64" ]]; then
    log_warn "两个架构的 ffmpeg 版本不同 (arm64=${FFVERSION_arm64}, amd64=${FFVERSION_amd64})，清单 ffmpeg.version 取 arm64 的值"
fi
FFMPEG_VERSION="$FFVERSION_arm64"

# ============================================================
# 4. deno：yt-dlp 的 JS 运行时（YouTube 挑战求解必需）——两架构 zip + 双重校验 + 许可材料
# ============================================================
log_info "[4/12] 抓取 deno (arm64 / amd64)"

if [[ -n "${DENO_TAG:-}" ]]; then
    DTAG="$DENO_TAG"; log_info "使用钉住的 deno tag: ${DTAG}"
else
    DTAG="$(fetch_stdout 'https://api.github.com/repos/denoland/deno/releases/latest' \
            | python3 -c 'import sys,json;print(json.load(sys.stdin)["tag_name"])' || true)"
    [[ -n "$DTAG" ]] || { log_error "无法获取 deno 最新 tag"; exit 1; }
    log_info "deno 最新 tag: ${DTAG}"
fi

# deno 资产取源：优先官方 CDN dl.deno.land（Deno 官方 install.sh 用的发行端点，与 GitHub release
# 是同一批文件——本机实测四个 .sha256sum 两边逐字节一致），失败再回 GitHub release（致命兜底）。
# 动机：2026-09-10 实测 GitHub 拉 deno zip 只有 ~0.13 MB/s 且会整条连接假死，dl.deno.land ~2.5 MB/s。
# 校验逻辑一字未改：仍以下载到的 sidecar 为准比对 zip 与解压后二进制的 sha256。
# 用法: fetch_deno_asset <文件名> <落盘路径>
fetch_deno_asset() {
    local name="$1" dest="$2"
    if fetch_optional "https://dl.deno.land/release/${DTAG}/${name}" "$dest"; then
        log_info "deno 资产取自 dl.deno.land: ${name}"
        return 0
    fi
    log_warn "dl.deno.land 取不到 ${name}，回退 GitHub release"
    fetch "https://github.com/denoland/deno/releases/download/${DTAG}/${name}" "$dest"
    log_info "deno 资产取自 GitHub release: ${name}"
}

DENO_DIR="${STAGE}/deno/${DTAG}"
for ARCH in arm64 amd64; do
    case "$ARCH" in arm64) TRIPLE=aarch64 ;; amd64) TRIPLE=x86_64 ;; esac
    ASSET="deno-${TRIPLE}-apple-darwin.zip"
    DEST="${DENO_DIR}/${ARCH}"; mkdir -p "$DEST"
    fetch_deno_asset "${ASSET}"                              "${DEST}/${ASSET}"
    fetch_deno_asset "${ASSET}.sha256sum"                    "${DEST}/${ASSET}.sha256sum"
    fetch_deno_asset "deno-${TRIPLE}-apple-darwin.sha256sum" "${DEST}/deno-${TRIPLE}-apple-darwin.sha256sum"
    EXPECTED="$(awk -v a="$ASSET" '$2 == a {print $1}' "${DEST}/${ASSET}.sha256sum" | head -1)"
    ACTUAL="$(sha256_of "${DEST}/${ASSET}")"
    [[ -n "$EXPECTED" && "$EXPECTED" == "$ACTUAL" ]] || { log_error "${ASSET} 校验不匹配: 期望 ${EXPECTED:-<空>}，实得 ${ACTUAL}"; exit 1; }
    # zip 内必须是根目录单个 deno，且解压后二进制哈希与上游 sidecar 一致
    UNPACK="$(mktemp -d)"; /usr/bin/ditto -x -k "${DEST}/${ASSET}" "$UNPACK"
    [[ -f "${UNPACK}/deno" ]] || { log_error "${ASSET} 内没有根目录 deno"; exit 1; }
    BIN_EXPECTED="$(awk '{print $1}' "${DEST}/deno-${TRIPLE}-apple-darwin.sha256sum" | head -1)"
    BIN_ACTUAL="$(sha256_of "${UNPACK}/deno")"
    [[ "$BIN_EXPECTED" == "$BIN_ACTUAL" ]] || { log_error "解压后 deno 哈希不匹配"; exit 1; }
    rm -rf "$UNPACK"
    eval "DENO_SHA_${ARCH}='${ACTUAL}'"; eval "DENO_SIZE_${ARCH}='$(size_of "${DEST}/${ASSET}")'"
    log_ok "deno ${ARCH} 校验通过"
done

# --- 许可材料：deno 自身 MIT + 组件精确版本表（Cargo.lock，对应 yt-dlp 的 COMPONENTS.txt）+ V8 许可全文（BSD-3 要求二进制分发附带）
if ! fetch_optional "https://raw.githubusercontent.com/denoland/deno/${DTAG}/LICENSE.md" "${DENO_DIR}/LICENSE.md"; then
    cp "${SCRIPT_DIR}/mirror-assets/deno-LICENSE.md" "${DENO_DIR}/LICENSE.md"
    log_warn "deno LICENSE.md 取自本地副本"
fi
grep -qF "MIT License" "${DENO_DIR}/LICENSE.md" && grep -qF "Deno authors" "${DENO_DIR}/LICENSE.md" \
    || { log_error "deno LICENSE.md 内容不是预期的 MIT 文本"; exit 1; }
fetch "https://raw.githubusercontent.com/denoland/deno/${DTAG}/Cargo.lock" "${DENO_DIR}/Cargo.lock"
grep -qF 'name = "v8"' "${DENO_DIR}/Cargo.lock" || { log_error "Cargo.lock 里没有 v8 crate，不是预期的 deno 工作区锁文件"; exit 1; }
V8_CRATE_VERSION="$(awk '/^name = "v8"$/{getline; sub(/^version = "/, ""); sub(/"$/, ""); print; exit}' "${DENO_DIR}/Cargo.lock")"
mkdir -p "${STAGE}/LICENSES"
if ! fetch_optional "https://raw.githubusercontent.com/v8/v8/main/LICENSE" "${STAGE}/LICENSES/V8-LICENSE.txt"; then
    cp "${SCRIPT_DIR}/mirror-assets/V8-LICENSE.txt" "${STAGE}/LICENSES/V8-LICENSE.txt"
    log_warn "V8 LICENSE 取自本地副本"
fi
grep -qF "Redistributions in binary form" "${STAGE}/LICENSES/V8-LICENSE.txt" \
    || { log_error "V8 LICENSE 内容不是预期的 BSD 文本"; exit 1; }
log_ok "deno 许可材料已就位（LICENSE.md / Cargo.lock / LICENSES/V8-LICENSE.txt，V8 crate ${V8_CRATE_VERSION}）"

# ============================================================
# 5. 入口文档：GPL 全文 + README
# ============================================================
log_info "[5/12] 生成入口文档（README.md / LICENSES）"

# GPL-3.0 全文是**静态内容**，不该每次发布都依赖 gnu.org 在线：
# 2026-09-06 实测 gnu.org 在本机链路连接超时（curl 28），重试全失败后把整条发布拖挂。
# 因此优先用仓库内自带副本 deploy/mirror-assets/GPL-3.0.txt
#   （取自 gnu.org 原文，35149 字节，
#    sha256 = 3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986）；
# 副本缺失才回退在线：gnu.org → 本站镜像上已发布的同一份；三者都拿不到才失败。
GPL_VENDORED="${SCRIPT_DIR}/mirror-assets/GPL-3.0.txt"
GPL_DEST="${STAGE}/LICENSES/GPL-3.0.txt"
mkdir -p "$(dirname "$GPL_DEST")"

if [[ -s "$GPL_VENDORED" ]]; then
    cp "$GPL_VENDORED" "$GPL_DEST"
    log_info "GPL-3.0.txt 使用仓库内副本: ${GPL_VENDORED}"
else
    log_warn "仓库内缺 ${GPL_VENDORED}，回退在线抓取"
    if fetch_optional "https://www.gnu.org/licenses/gpl-3.0.txt" "$GPL_DEST"; then
        log_info "GPL-3.0.txt 取自 gnu.org"
    elif fetch_optional "${TOOLS_URL_BASE}/LICENSES/GPL-3.0.txt" "$GPL_DEST"; then
        log_warn "gnu.org 不可达，GPL-3.0.txt 取自本站镜像上已发布的副本"
    else
        log_error "GPL-3.0.txt 三个来源都拿不到（仓库副本 / gnu.org / 本站镜像）"
        exit 1
    fi
fi

if [[ ! -s "$GPL_DEST" ]]; then
    log_error "GPL-3.0.txt 为空"
    exit 1
fi
# 结构自检：确认拿到的确实是 GPL v3 全文，而不是错误页 / 半截文件
if ! grep -qF "GNU GENERAL PUBLIC LICENSE" "$GPL_DEST" \
   || ! grep -qF "Version 3, 29 June 2007" "$GPL_DEST" \
   || ! grep -qF "END OF TERMS AND CONDITIONS" "$GPL_DEST"; then
    log_error "GPL-3.0.txt 内容不像 GPL v3 全文，已中止"
    exit 1
fi

MIRROR_TAG="$TAG" \
MIRROR_YTDLP_SHA="$YTDLP_SHA" MIRROR_YTDLP_SIZE="$YTDLP_SIZE" \
MIRROR_FFMPEG_VERSION="$FFMPEG_VERSION" \
MIRROR_ARM64_ID="$BUILD_ID_arm64" MIRROR_ARM64_VER="$FFVERSION_arm64" \
MIRROR_ARM64_SHA="$FFSHA_arm64" MIRROR_ARM64_SIZE="$FFSIZE_arm64" MIRROR_ARM64_TIME="$BUILDTIME_arm64" \
MIRROR_AMD64_ID="$BUILD_ID_amd64" MIRROR_AMD64_VER="$FFVERSION_amd64" \
MIRROR_AMD64_SHA="$FFSHA_amd64" MIRROR_AMD64_SIZE="$FFSIZE_amd64" MIRROR_AMD64_TIME="$BUILDTIME_amd64" \
MIRROR_DENO_TAG="$DTAG" MIRROR_DENO_V8_CRATE="$V8_CRATE_VERSION" \
MIRROR_DENO_ARM64_SHA="$DENO_SHA_arm64" MIRROR_DENO_ARM64_SIZE="$DENO_SIZE_arm64" \
MIRROR_DENO_AMD64_SHA="$DENO_SHA_amd64" MIRROR_DENO_AMD64_SIZE="$DENO_SIZE_amd64" \
MIRROR_URL_BASE="$TOOLS_URL_BASE" \
python3 - "${STAGE}/README.md" <<'PY'
import datetime
import os
import sys

out_path = sys.argv[1]
E = os.environ
tag = E["MIRROR_TAG"]
dtag = E["MIRROR_DENO_TAG"]
generated = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

L = []
add = L.append

add("# VowKy 工具镜像（yt-dlp / ffmpeg / deno）")
add("")
add("本目录是 [VowKy](https://vowky.com) 「链接转文字」功能所需第三方命令行工具的镜像。")
add("VowKy 首次转写链接时需要下载 yt-dlp、ffmpeg 与 deno（yt-dlp 的 JavaScript 运行时，YouTube 解析必需）；上游站点在部分网络下过慢或不可达，")
add("因此把上游发行物原样镜像到本站，App 优先从这里取、失败再回退上游。")
add("")
add("**镜像的二进制与上游发行物逐字节相同，未做任何修改、重打包或重编译。**")
add("每个文件的 SHA-256 与字节数都钉在已签名的清单 `manifest.signed.json` 里；")
add("App 用内置的 Ed25519 公钥验签后才会使用清单，校验不通过一律拒绝安装。")
add("")
add("## 目录结构")
add("")
add("```")
add("manifest.signed.json                     唯一清单入口（Ed25519 签名信封）")
add("README.md                                本文件")
add("LICENSES/GPL-3.0.txt                     GNU GPL v3 全文")
add("LICENSES/V8-LICENSE.txt                  V8 (BSD-3-Clause) 许可全文")
add("yt-dlp/<tag>/yt-dlp_macos                yt-dlp 官方 macOS 发行物（原始二进制）")
add("yt-dlp/<tag>/SHA2-256SUMS                yt-dlp 官方校验文件")
add("yt-dlp/<tag>/yt-dlp-<tag>.tar.gz         yt-dlp 对应源码")
add("yt-dlp/<tag>/LICENSE                     yt-dlp 许可证")
add("yt-dlp/<tag>/build.yml                   yt-dlp 官方 PyInstaller 打包工作流")
add("yt-dlp/<tag>/COMPONENTS.txt              组件 → 精确版本 → 对应源码 对应表")
add("ffmpeg/<buildId>/ffmpeg-<version>.tar.xz ffmpeg 对应源码")
add("ffmpeg/<buildId>/<arch>/ffmpeg.zip       ffmpeg 静态构建（原始发行物）")
add("ffmpeg/<buildId>/<arch>/ffmpeg.zip.sha256  上游校验文件")
add("ffmpeg/<buildId>/<arch>/versions.txt     该构建各静态链接组件的精确版本")
add("ffmpeg/<buildId>/<arch>/detail.html      上游构建详情页快照")
add("deno/<tag>/<arch>/deno-<triple>-apple-darwin.zip            deno 官方发行物（原始 zip）")
add("deno/<tag>/<arch>/deno-<triple>-apple-darwin.zip.sha256sum  上游 zip 校验文件")
add("deno/<tag>/<arch>/deno-<triple>-apple-darwin.sha256sum      上游「解压后二进制」校验文件")
add("deno/<tag>/LICENSE.md                    deno 许可证（MIT）")
add("deno/<tag>/Cargo.lock                    deno 该版本静态链接组件的精确名称与版本")
add("```")
add("")
add("版本目录一经发布即不可变：同一 `<tag>` / `<buildId>` 下的文件永不覆盖，只会新增新版本目录。")
add("")
add("## yt-dlp")
add("")
add("- 版本（tag）：`%s`" % tag)
add("- 文件：`yt-dlp/%s/yt-dlp_macos`（SHA-256 `%s`，%s 字节）" % (tag, E["MIRROR_YTDLP_SHA"], E["MIRROR_YTDLP_SIZE"]))
add("- 上游：<https://github.com/yt-dlp/yt-dlp/releases/tag/%s>" % tag)
add("")
add("`yt-dlp_macos` 是 PyInstaller 打包的发行物。yt-dlp 官方 README 原文：")
add("")
add("> the PyInstaller-bundled executables include GPLv3+ licensed code, and as such the combined work is licensed under GPLv3+")
add("")
add("因此本目录分发的 `yt-dlp_macos` **整体按 GPLv3+ 授权**。对应源码与构建材料：")
add("")
add("- yt-dlp 自身源码：`yt-dlp/%s/yt-dlp-%s.tar.gz`" % (tag, tag))
add("- 打包进该二进制的 Python 解释器与各第三方库的**精确版本与源码地址**：`yt-dlp/%s/COMPONENTS.txt`" % tag)
add("  （该表由本目录二进制自身的 `-v` 输出生成，与二进制严格对应）")
add("- 构建配置：`yt-dlp/%s/build.yml`（yt-dlp 官方 PyInstaller 打包工作流）" % tag)
add("- 许可证：`yt-dlp/%s/LICENSE`，GPL v3 全文见 `LICENSES/GPL-3.0.txt`" % tag)
add("")
add("## ffmpeg")
add("")
add("- 版本：`%s`" % E["MIRROR_FFMPEG_VERSION"])
add("- arm64 构建：buildId `%s`（版本 %s，构建时间 %s）" % (E["MIRROR_ARM64_ID"], E["MIRROR_ARM64_VER"], E["MIRROR_ARM64_TIME"]))
add("  - `ffmpeg/%s/arm64/ffmpeg.zip`（SHA-256 `%s`，%s 字节）" % (E["MIRROR_ARM64_ID"], E["MIRROR_ARM64_SHA"], E["MIRROR_ARM64_SIZE"]))
add("- amd64 构建：buildId `%s`（版本 %s，构建时间 %s）" % (E["MIRROR_AMD64_ID"], E["MIRROR_AMD64_VER"], E["MIRROR_AMD64_TIME"]))
add("  - `ffmpeg/%s/amd64/ffmpeg.zip`（SHA-256 `%s`，%s 字节）" % (E["MIRROR_AMD64_ID"], E["MIRROR_AMD64_SHA"], E["MIRROR_AMD64_SIZE"]))
add("- 二进制来自 <https://ffmpeg.martin-riedl.de/>（macOS 静态构建）")
add("")
add("这些构建以 `--enable-gpl` 配置编译，因此**按 GPL v3 分发**（全文见 `LICENSES/GPL-3.0.txt`）。")
add("对应源码与构建材料：")
add("")
add("- ffmpeg 自身源码：`ffmpeg/<buildId>/ffmpeg-%s.tar.xz`（来自 <https://ffmpeg.org/releases/>）" % E["MIRROR_FFMPEG_VERSION"])
add("- 静态链接进该二进制的每个第三方组件的**精确版本**：`ffmpeg/<buildId>/<arch>/versions.txt`")
add("  （按 `versions.txt` 里的项目名与版本号到各自上游取对应源码）")
add("- 构建脚本：<https://git.martin-riedl.de/ffmpeg/build-script>")
add("- 构建详情页快照：`ffmpeg/<buildId>/<arch>/detail.html`；`buildId` 前缀即构建时间的 Unix 时间戳")
add("")
add("## deno")
add("")
add("- 版本（tag）：`%s`" % dtag)
add("- arm64：`deno/%s/arm64/deno-aarch64-apple-darwin.zip`（SHA-256 `%s`，%s 字节）"
    % (dtag, E["MIRROR_DENO_ARM64_SHA"], E["MIRROR_DENO_ARM64_SIZE"]))
add("- amd64：`deno/%s/amd64/deno-x86_64-apple-darwin.zip`（SHA-256 `%s`，%s 字节）"
    % (dtag, E["MIRROR_DENO_AMD64_SHA"], E["MIRROR_DENO_AMD64_SIZE"]))
add("- 上游：<https://github.com/denoland/deno/releases/tag/%s>" % dtag)
add("")
add("deno 自身按 **MIT** 分发（许可全文 `deno/%s/LICENSE.md`）。" % dtag)
add("上游发行物 zip 只含二进制、不附带依赖声明（deno 议题 [#13515](https://github.com/denoland/deno/issues/13515)），本镜像补齐：")
add("")
add("- 二进制静态链接的 V8（rusty_v8 crate `%s`，BSD-3-Clause）许可全文：`LICENSES/V8-LICENSE.txt`"
    % E["MIRROR_DENO_V8_CRATE"])
add("- 其余 Rust crate 的精确名称与版本：`deno/%s/Cargo.lock`；各 crate 的许可以 crates.io 元数据为准" % dtag)
add("  （绝大多数为 MIT / Apache-2.0，均只要求保留版权声明）")
add("- 对应源码：<https://github.com/denoland/deno/tree/%s>" % dtag)
add("")
add("## 清单与验证方式")
add("")
add("`manifest.signed.json` 是一个 Ed25519 签名信封：")
add("")
add("```json")
add("{")
add('  "schema": 1,')
add('  "manifest": "<base64(manifest.json 原始字节)>",')
add('  "signature": "<base64(Ed25519 签名)>"')
add("}")
add("```")
add("")
add("`manifest` 解 base64 后即清单原文（schema 1），结构：")
add("")
add("```json")
add("{")
add('  "schema": 1,')
add('  "generatedAt": "<UTC ISO8601>",')
add('  "ytDlp":  { "tag": "...", "asset": "yt-dlp/<tag>/yt-dlp_macos", "sha256": "...", "size": 0 },')
add('  "ffmpeg": { "version": "...",')
add('              "arm64": { "buildId": "...", "asset": "ffmpeg/<buildId>/arm64/ffmpeg.zip", "sha256": "...", "size": 0 },')
add('              "amd64": { "buildId": "...", "asset": "ffmpeg/<buildId>/amd64/ffmpeg.zip", "sha256": "...", "size": 0 } },')
add('  "deno":   { "tag": "...",')
add('              "arm64": { "asset": "deno/<tag>/arm64/deno-aarch64-apple-darwin.zip", "sha256": "...", "size": 0 },')
add('              "amd64": { "asset": "deno/<tag>/amd64/deno-x86_64-apple-darwin.zip",  "sha256": "...", "size": 0 } }')
add("}")
add("```")
add("")
add("其中 `deno` 是**可选键**（2026-09 加入）：清单里没有它表示本镜像暂无 deno，App 会回退到上游 GitHub 下载。")
add("")
add("签名对象是解 base64 后的**清单原始字节**，用与 VowKy 自动更新相同的那把 Ed25519 密钥签发；")
add("VowKy 用内置公钥（`SUPublicEDKey`）验签。任何人都可以自行核对：")
add("")
add("```bash")
add("# 需要 Sparkle 的 sign_update 工具与 VowKy 的公钥")
add("deploy/mirror-verify.sh --url %s/manifest.signed.json" % E["MIRROR_URL_BASE"])
add("deploy/mirror-verify.sh --file ./manifest.signed.json")
add("```")
add("")
add("验签通过时脚本把清单 JSON 打印到 stdout 并以 0 退出；任何一步失败都以 1 退出。")
add("拿到清单后，用 `shasum -a 256 <文件>` 与清单里的 `sha256` 逐一比对即可确认资产未被篡改。")
add("")
add("---")
add("")
add("生成时间：%s" % generated)
add("生成方式：`deploy/mirror-tools.sh`（VowKy 仓库）")
add("")

with open(out_path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(L))
PY

log_ok "README.md / LICENSES/GPL-3.0.txt 已生成"

# ============================================================
# 6. 生成清单、签名、封装信封、本地自验
# ============================================================
log_info "[6/12] 生成签名清单"

MIRROR_TAG="$TAG" MIRROR_YTDLP_SHA="$YTDLP_SHA" MIRROR_YTDLP_SIZE="$YTDLP_SIZE" \
MIRROR_FFMPEG_VERSION="$FFMPEG_VERSION" \
MIRROR_ARM64_ID="$BUILD_ID_arm64" MIRROR_ARM64_SHA="$FFSHA_arm64" MIRROR_ARM64_SIZE="$FFSIZE_arm64" \
MIRROR_AMD64_ID="$BUILD_ID_amd64" MIRROR_AMD64_SHA="$FFSHA_amd64" MIRROR_AMD64_SIZE="$FFSIZE_amd64" \
MIRROR_DENO_TAG="$DTAG" \
MIRROR_DENO_ARM64_SHA="$DENO_SHA_arm64" MIRROR_DENO_ARM64_SIZE="$DENO_SIZE_arm64" \
MIRROR_DENO_AMD64_SHA="$DENO_SHA_amd64" MIRROR_DENO_AMD64_SIZE="$DENO_SIZE_amd64" \
python3 - "${STAGE}/manifest.json" <<'PY'
import datetime
import json
import os
import sys

E = os.environ
manifest = {
    "schema": 1,
    "generatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ytDlp": {
        "tag": E["MIRROR_TAG"],
        "asset": "yt-dlp/%s/yt-dlp_macos" % E["MIRROR_TAG"],
        "sha256": E["MIRROR_YTDLP_SHA"],
        "size": int(E["MIRROR_YTDLP_SIZE"]),
    },
    "ffmpeg": {
        "version": E["MIRROR_FFMPEG_VERSION"],
        "arm64": {
            "buildId": E["MIRROR_ARM64_ID"],
            "asset": "ffmpeg/%s/arm64/ffmpeg.zip" % E["MIRROR_ARM64_ID"],
            "sha256": E["MIRROR_ARM64_SHA"],
            "size": int(E["MIRROR_ARM64_SIZE"]),
        },
        "amd64": {
            "buildId": E["MIRROR_AMD64_ID"],
            "asset": "ffmpeg/%s/amd64/ffmpeg.zip" % E["MIRROR_AMD64_ID"],
            "sha256": E["MIRROR_AMD64_SHA"],
            "size": int(E["MIRROR_AMD64_SIZE"]),
        },
    },
    # deno 是 schema 1 的**可选**顶层键（2026-09 加入）：老 App 用非可选字段解码、忽略此键，不受影响。
    "deno": {
        "tag": E["MIRROR_DENO_TAG"],
        "arm64": {
            "asset": "deno/%s/arm64/deno-aarch64-apple-darwin.zip" % E["MIRROR_DENO_TAG"],
            "sha256": E["MIRROR_DENO_ARM64_SHA"],
            "size": int(E["MIRROR_DENO_ARM64_SIZE"]),
        },
        "amd64": {
            "asset": "deno/%s/amd64/deno-x86_64-apple-darwin.zip" % E["MIRROR_DENO_TAG"],
            "sha256": E["MIRROR_DENO_AMD64_SHA"],
            "size": int(E["MIRROR_DENO_AMD64_SIZE"]),
        },
    },
}

with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, sort_keys=True, indent=2, ensure_ascii=False)
PY

SIG="$("$SIGN_UPDATE" -p "${STAGE}/manifest.json" | tr -d '\n')"
if [[ -z "$SIG" ]]; then
    log_error "sign_update 未返回签名（私钥不可用？）"
    exit 1
fi
if ! "$SIGN_UPDATE" --verify "${STAGE}/manifest.json" "$SIG" >/dev/null 2>&1; then
    log_error "刚生成的签名自验失败"
    exit 1
fi
log_ok "清单已签名并通过 sign_update --verify"

MIRROR_SIG="$SIG" python3 - "${STAGE}/manifest.json" "${STAGE}/manifest.signed.json" <<'PY'
import base64
import json
import os
import sys

with open(sys.argv[1], "rb") as fh:
    manifest_bytes = fh.read()

envelope = {
    "schema": 1,
    "manifest": base64.b64encode(manifest_bytes).decode("ascii"),
    "signature": os.environ["MIRROR_SIG"],
}

with open(sys.argv[2], "w", encoding="utf-8") as fh:
    json.dump(envelope, fh, indent=2)
    fh.write("\n")
PY

if ! "${SCRIPT_DIR}/mirror-verify.sh" --file "${STAGE}/manifest.signed.json" >/dev/null; then
    log_error "本地签名信封自验失败"
    exit 1
fi
log_ok "manifest.signed.json 本地自验通过"

# ============================================================
# 7. 上传不可变目录（--ignore-existing，永不覆盖已发布版本）
# ============================================================
log_info "[7/12] 上传不可变资产目录"

ssh "$SERVER" "mkdir -p ${TOOLS_REMOTE}"
rsync_retry -avz --ignore-existing "${STAGE}/yt-dlp/" "${SERVER}:${TOOLS_REMOTE}/yt-dlp/"
rsync_retry -avz --ignore-existing "${STAGE}/ffmpeg/" "${SERVER}:${TOOLS_REMOTE}/ffmpeg/"
rsync_retry -avz --ignore-existing "${STAGE}/deno/"   "${SERVER}:${TOOLS_REMOTE}/deno/"
log_ok "不可变资产已上传"

# ============================================================
# 8. 线上核验：每个不可变文件的 content-length 必须与本地一致
# ============================================================
log_info "[8/12] 线上核验不可变资产"

VERIFY_FAILED=0
VERIFY_COUNT=0
for REL in $(cd "$STAGE" && find yt-dlp ffmpeg deno -type f | sort); do
    LOCAL_SIZE="$(size_of "${STAGE}/${REL}")"
    REMOTE_SIZE="$(curl -fsSIL --retry 3 --retry-delay 2 --retry-all-errors \
                        --connect-timeout 10 --max-time 60 -A "$UA" \
                        "${TOOLS_URL_BASE}/${REL}" 2>/dev/null \
                   | tr -d '\r' | awk 'tolower($1) == "content-length:" { print $2 }' | tail -1 || true)"
    VERIFY_COUNT=$((VERIFY_COUNT + 1))
    if [[ -z "$REMOTE_SIZE" ]]; then
        log_error "线上不可访问: ${TOOLS_URL_BASE}/${REL}"
        VERIFY_FAILED=1
    elif [[ "$REMOTE_SIZE" != "$LOCAL_SIZE" ]]; then
        log_error "长度不一致: ${REL} 本地 ${LOCAL_SIZE} / 线上 ${REMOTE_SIZE}"
        VERIFY_FAILED=1
    fi
done
if [[ "$VERIFY_FAILED" -ne 0 ]]; then
    log_error "不可变资产核验失败，已中止（签名信封未发布，旧信封仍然有效）"
    exit 1
fi
log_ok "${VERIFY_COUNT} 个不可变文件线上核验通过"

# ============================================================
# 9. 上传入口文档（覆盖更新）
# ============================================================
log_info "[9/12] 上传入口文档（README.md / LICENSES）"
rsync_retry -avz "${STAGE}/README.md" "${STAGE}/LICENSES" "${SERVER}:${TOOLS_REMOTE}/"
log_ok "入口文档已更新"

# ============================================================
# 10. 验收用中止点
# ============================================================
if [[ "${MIRROR_ABORT_BEFORE_MANIFEST:-}" == "1" ]]; then
    log_warn "[10/12] 按测试要求在发布信封前中止"
    exit 3
fi

# ============================================================
# 11. 原子发布签名信封（.tmp + mv，单文件一次替换）
# ============================================================
log_info "[11/12] 原子发布 manifest.signed.json"
rsync_retry -avz "${STAGE}/manifest.signed.json" "${SERVER}:${TOOLS_REMOTE}/manifest.signed.json.tmp"
ssh "$SERVER" "mv -f ${TOOLS_REMOTE}/manifest.signed.json.tmp ${TOOLS_REMOTE}/manifest.signed.json"
log_ok "签名信封已原子替换"

# ============================================================
# 12. 线上自检
# ============================================================
log_info "[12/12] 线上自检"

ONLINE_MANIFEST="$("${SCRIPT_DIR}/mirror-verify.sh" --url "${TOOLS_URL_BASE}/manifest.signed.json")"
if [[ -z "$ONLINE_MANIFEST" ]]; then
    log_error "线上签名信封验签失败"
    exit 1
fi

if ! printf '%s' "$ONLINE_MANIFEST" | MIRROR_TAG="$TAG" MIRROR_ARM64_ID="$BUILD_ID_arm64" MIRROR_AMD64_ID="$BUILD_ID_amd64" MIRROR_DENO_TAG="$DTAG" python3 -c '
import json, os, sys
m = json.load(sys.stdin)
E = os.environ
problems = []
if m["ytDlp"]["tag"] != E["MIRROR_TAG"]:
    problems.append("ytDlp.tag=%s 期望 %s" % (m["ytDlp"]["tag"], E["MIRROR_TAG"]))
if m["ffmpeg"]["arm64"]["buildId"] != E["MIRROR_ARM64_ID"]:
    problems.append("ffmpeg.arm64.buildId=%s 期望 %s" % (m["ffmpeg"]["arm64"]["buildId"], E["MIRROR_ARM64_ID"]))
if m["ffmpeg"]["amd64"]["buildId"] != E["MIRROR_AMD64_ID"]:
    problems.append("ffmpeg.amd64.buildId=%s 期望 %s" % (m["ffmpeg"]["amd64"]["buildId"], E["MIRROR_AMD64_ID"]))
if m.get("deno", {}).get("tag") != E["MIRROR_DENO_TAG"]:
    problems.append("deno.tag=%s 期望 %s" % (m.get("deno", {}).get("tag"), E["MIRROR_DENO_TAG"]))
if problems:
    sys.stderr.write("; ".join(problems) + "\n")
    raise SystemExit(1)
'; then
    log_error "线上清单内容与本次发布不一致"
    exit 1
fi

log_ok "镜像已更新: yt-dlp ${TAG}, ffmpeg ${BUILD_ID_arm64}/${BUILD_ID_amd64}, deno ${DTAG}"
