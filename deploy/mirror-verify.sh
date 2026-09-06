#!/bin/bash
# deploy/mirror-verify.sh — 校验 VowKy 工具镜像的签名信封 manifest.signed.json
#
# 用法:
#   deploy/mirror-verify.sh --url  https://vowky.com/downloads/tools/manifest.signed.json
#   deploy/mirror-verify.sh --file /path/to/manifest.signed.json
#
# 行为：取信封 → 解 base64 得清单原始字节 → sign_update --verify 用 Sparkle Ed25519 密钥验签
#       → 验签通过则把清单 JSON 打印到 stdout 并 exit 0；任何一步失败打印原因到 stderr 并 exit 1。
#
# 说明：本脚本刻意不 source config.sh —— 它要能在任意终端（含 E2E 的 200 次连续读取循环）
#       独立、轻量地跑，不依赖 config.local.sh 与 Xcode 工具链检查。

set -euo pipefail

usage() {
    echo "用法: $(basename "$0") --url <url> | --file <path>" >&2
}

MODE=""
TARGET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)
            [[ $# -ge 2 ]] || { usage; exit 1; }
            MODE="url"; TARGET="$2"; shift 2 ;;
        --file)
            [[ $# -ge 2 ]] || { usage; exit 1; }
            MODE="file"; TARGET="$2"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "✗ 未知参数: $1" >&2; usage; exit 1 ;;
    esac
done

if [[ -z "$MODE" || -z "$TARGET" ]]; then
    usage
    exit 1
fi

# ------------------------------------------------------------
# 定位 sign_update（与 deploy.sh / mirror-tools.sh 同一查找顺序）
# ------------------------------------------------------------
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
    echo "✗ 未找到 sign_update，无法验签" >&2
    exit 1
fi

TMPDIR_VERIFY="$(mktemp -d "${TMPDIR:-/tmp}/vowky-mirror-verify.XXXXXX")"
cleanup() { rm -rf "$TMPDIR_VERIFY"; }
trap cleanup EXIT

ENVELOPE="${TMPDIR_VERIFY}/manifest.signed.json"

if [[ "$MODE" == "url" ]]; then
    if ! curl -fsSL --connect-timeout 10 --max-time 60 -o "$ENVELOPE" "$TARGET"; then
        echo "✗ 无法下载签名信封: $TARGET" >&2
        exit 1
    fi
else
    if [[ ! -f "$TARGET" ]]; then
        echo "✗ 文件不存在: $TARGET" >&2
        exit 1
    fi
    cp "$TARGET" "$ENVELOPE"
fi

MANIFEST="${TMPDIR_VERIFY}/manifest.json"
SIGNATURE=""

# 解信封：schema 必须为 1；manifest/signature 必须是合法 base64。
# 清单原始字节写入 $MANIFEST（逐字节还原，验签对象即此文件内容），签名打印到 stdout 供 shell 捕获。
if ! SIGNATURE="$(python3 - "$ENVELOPE" "$MANIFEST" <<'PY'
import base64
import binascii
import json
import sys

envelope_path, manifest_path = sys.argv[1], sys.argv[2]

try:
    with open(envelope_path, "rb") as fh:
        envelope = json.load(fh)
except Exception as exc:  # noqa: BLE001
    sys.stderr.write("信封不是合法 JSON: %s\n" % exc)
    raise SystemExit(1)

if not isinstance(envelope, dict):
    sys.stderr.write("信封顶层不是 JSON 对象\n")
    raise SystemExit(1)

if envelope.get("schema") != 1:
    sys.stderr.write("信封 schema 不是 1: %r\n" % (envelope.get("schema"),))
    raise SystemExit(1)

manifest_b64 = envelope.get("manifest")
signature = envelope.get("signature")
if not isinstance(manifest_b64, str) or not isinstance(signature, str):
    sys.stderr.write("信封缺少 manifest / signature 字段\n")
    raise SystemExit(1)

try:
    manifest_bytes = base64.b64decode(manifest_b64, validate=True)
except (binascii.Error, ValueError) as exc:
    sys.stderr.write("manifest 字段不是合法 base64: %s\n" % exc)
    raise SystemExit(1)

try:
    base64.b64decode(signature, validate=True)
except (binascii.Error, ValueError) as exc:
    sys.stderr.write("signature 字段不是合法 base64: %s\n" % exc)
    raise SystemExit(1)

with open(manifest_path, "wb") as fh:
    fh.write(manifest_bytes)

sys.stdout.write(signature)
PY
)"; then
    echo "✗ 签名信封结构无效: $TARGET" >&2
    exit 1
fi

if [[ -z "$SIGNATURE" ]]; then
    echo "✗ 签名信封缺少签名" >&2
    exit 1
fi

if ! "$SIGN_UPDATE" --verify "$MANIFEST" "$SIGNATURE" >/dev/null 2>"${TMPDIR_VERIFY}/verify.err"; then
    echo "✗ Ed25519 验签失败: $TARGET" >&2
    sed 's/^/  /' "${TMPDIR_VERIFY}/verify.err" >&2 || true
    exit 1
fi

# 验签通过后再做一次结构自检（schema 必须为 1），并把清单原样打印出来。
if ! python3 - "$MANIFEST" <<'PY'
import json
import sys

with open(sys.argv[1], "rb") as fh:
    manifest = json.load(fh)

if manifest.get("schema") != 1:
    sys.stderr.write("清单 schema 不是 1: %r\n" % (manifest.get("schema"),))
    raise SystemExit(1)
PY
then
    echo "✗ 清单结构无效（验签已通过，但 schema 不符）" >&2
    exit 1
fi

cat "$MANIFEST"

# 清单末尾补一个换行，便于终端阅读与 shell 拼接
echo
