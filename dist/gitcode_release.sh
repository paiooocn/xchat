#!/usr/bin/env bash
# 发布构建产物到 GitCode Release：
#   1) 确保 tag 对应的 Release 存在（GET releases/tags/:tag，不存在则 POST 创建，带重试以容忍并行任务竞态）
#   2) 逐个文件获取附件上传地址（GET releases/:tag/upload_url）并 PUT 上传（带 OBS 回调头）
#   3) 同名附件已存在时跳过（保证重跑幂等）
#
# 用法: bash dist/gitcode_release.sh <artifact...>
#
# 环境变量:
#   GITCODE_TOKEN   必填  GitCode 私人令牌（access_token，需有仓库 Release 读写权限）
#   GITCODE_OWNER   必填  仓库所属空间地址（企业/组织/个人的 path）
#   GITCODE_REPO    必填  仓库路径
#   TAG_NAME        必填  tag 名称，如 v0.1.9
#   RELEASE_NAME    选填  Release 名称（默认同 TAG_NAME）
#   RELEASE_BODY    选填  Release 描述
#   RELEASE_STATUS  选填  latest | pre（默认 latest）
#   GITCODE_API     选填  API 基址（默认 https://api.gitcode.com/api/v5）
set -euo pipefail

API="${GITCODE_API:-https://api.gitcode.com/api/v5}"
TOKEN="${GITCODE_TOKEN:?GITCODE_TOKEN is required}"
OWNER="${GITCODE_OWNER:?GITCODE_OWNER is required}"
REPO="${GITCODE_REPO:?GITCODE_REPO is required}"
TAG="${TAG_NAME:?TAG_NAME is required}"
NAME="${RELEASE_NAME:-$TAG}"
BODY="${RELEASE_BODY:-}"
STATUS="${RELEASE_STATUS:-latest}"

command -v jq >/dev/null 2>&1 || { echo "!! jq is required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "!! curl is required" >&2; exit 1; }
[ $# -ge 1 ] || { echo "usage: $0 <artifact...>" >&2; exit 2; }

say()  { printf '==> %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

RELEASE_JSON=""

# --- 1. 确保 Release 存在 ---------------------------------------------------
ensure_release() {
  local code attempt
  for attempt in 1 2 3 4; do
    code=$(curl -sS -o "$TMP/release.json" -w '%{http_code}' -G \
      "$API/repos/$OWNER/$REPO/releases/tags/$TAG" \
      --data-urlencode "access_token=$TOKEN" || true)
    if [ "$code" = "200" ]; then
      RELEASE_JSON="$(cat "$TMP/release.json")"
      say "release 已存在: $TAG"
      return 0
    fi

    say "release 不存在（HTTP $code），创建中: $TAG  ($NAME / $STATUS)"
    code=$(curl -sS -o "$TMP/release.json" -w '%{http_code}' -X POST \
      "$API/repos/$OWNER/$REPO/releases?access_token=$TOKEN" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg tag "$TAG" --arg name "$NAME" --arg body "$BODY" --arg st "$STATUS" \
           '{tag_name:$tag, name:$name, body:$body, release_status:$st}')" || true)
    if [ "$code" = "200" ] || [ "$code" = "201" ]; then
      RELEASE_JSON="$(cat "$TMP/release.json")"
      say "release 创建成功: $TAG"
      return 0
    fi

    warn "创建未成功（HTTP $code: $(head -c 300 "$TMP/release.json")），${attempt}s 后重试..."
    sleep "$attempt"
  done

  warn "无法创建/获取 release: $TAG"
  exit 1
}

# --- 2. 上传单个附件 --------------------------------------------------------
upload_asset() {
  local file="$1"
  local fname resp url hname hval
  fname="$(basename "$file")"

  if jq -e --arg n "$fname" '.assets[]? | select(.name == $n)' \
       <<<"$RELEASE_JSON" >/dev/null 2>&1; then
    say "附件已存在，跳过: $fname"
    return 0
  fi

  resp=$(curl -sS -G "$API/repos/$OWNER/$REPO/releases/$TAG/upload_url" \
    --data-urlencode "access_token=$TOKEN" \
    --data-urlencode "file_name=$fname")
  url=$(jq -r '.url // empty' <<<"$resp")
  [ -n "$url" ] || { warn "获取上传地址失败: $resp"; return 1; }

  local args=(-sS -f -T "$file" "$url")
  for hname in x-obs-meta-project-id x-obs-acl x-obs-callback Content-Type; do
    hval=$(jq -r --arg k "$hname" '.headers[$k] // ""' <<<"$resp")
    if [ "$hname" = "Content-Type" ] && [ -z "$hval" ]; then
      hval="application/octet-stream"
    fi
    [ -n "$hval" ] && args+=(-H "$hname: $hval")
  done

  say "上传 $fname（$(du -h "$file" | cut -f1)）"
  curl "${args[@]}" >/dev/null
  say "上传完成: $fname"
}

ensure_release
for f in "$@"; do
  [ -f "$f" ] || { warn "文件不存在: $f"; exit 1; }
  upload_asset "$f"
done

say "GITCODE_RELEASE_DONE ($TAG)"
