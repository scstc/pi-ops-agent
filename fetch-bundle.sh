#!/usr/bin/env bash
# fetch-bundle.sh —— 在联网的 Linux x86_64 机器上执行一次,备齐离线安装全部产物到 bundle/。
# 之后把整个仓库目录(含 bundle/)拷进内网服务器,运行 ./install.sh 即完成安装
# (全程离线、不需要 root、装完免手动配置大模型)。
#
# 用法: ./fetch-bundle.sh [--skip-4b]    # 默认备 qwen3.5-2b(默认模型)与 qwen3.5-4b(A/B 备选)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="$ROOT/bundle"
mkdir -p "$BUNDLE"
# 清扫上次中断下载的残留(无续传语义,残留只会污染清单)
rm -f "$BUNDLE"/*.part

# ---- 钉死的兜底版本(动态解析失败时用;更新时注意约束:node ≥22.19 才能跑 pi) ----
NODE_VER_FALLBACK="22.20.0"
LLAMA_TAG_FALLBACK="b10901"
NODE_DIST="https://registry.npmmirror.com/-/binary/node"
NPM_REGISTRY="https://registry.npmmirror.com"
PI_PKG="@earendil-works/pi-coding-agent"

log() { printf '\033[1;32m[fetch]\033[0m %s\n' "$*"; }

fetch() { # fetch <url> <dest> —— 断点重试下载
  local url="$1" dest="$2" tries=0
  while [ "$tries" -lt 3 ]; do
    if curl -fL --retry 2 --connect-timeout 15 -o "$dest.part" "$url"; then
      mv "$dest.part" "$dest"; return 0
    fi
    tries=$((tries + 1)); echo "  重试($tries/3): $url"; sleep 2
  done
  echo "下载失败: $url" >&2; return 1
}

# ---------- 1. Node.js v22 LTS linux-x64 ----------
if ls "$BUNDLE"/node-v22*-linux-x64.tar.xz >/dev/null 2>&1; then
  log "node tarball 已存在,跳过"
else
  log "解析 npmmirror 最新 Node v22 …"
  ver="$(curl -fsSL -m 20 "$NODE_DIST/latest-v22.x/" \
    | grep -oE '"name":"node-v[0-9.]+-linux-x64\.tar\.xz"' | cut -d'"' -f4 \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1 || true)"
  [ -n "$ver" ] || ver="$NODE_VER_FALLBACK"
  log "Node v$ver"
  fetch "$NODE_DIST/latest-v22.x/node-v$ver-linux-x64.tar.xz" \
        "$BUNDLE/node-v$ver-linux-x64.tar.xz"
fi
NODE_TAR="$(ls "$BUNDLE"/node-v22*-linux-x64.tar.xz | head -1)"

# ---------- 2. llama.cpp(最新带 ubuntu-x64 资产的 release)----------
if ls "$BUNDLE"/llama-*-bin-ubuntu-x64.tar.gz >/dev/null 2>&1; then
  log "llama.cpp 已存在,跳过"
else
  log "解析 llama.cpp 最新 release …"
  tag="$(curl -fsSL -m 20 "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=15" \
    | grep -oE '"tag_name": *"[^"]+"' | cut -d'"' -f4 | while read -r t; do
        curl -fsSIL -m 15 -o /dev/null \
          "https://github.com/ggml-org/llama.cpp/releases/download/$t/llama-$t-bin-ubuntu-x64.tar.gz" \
          && { echo "$t"; break; }
      done || true)"
  [ -n "$tag" ] || tag="$LLAMA_TAG_FALLBACK"
  log "llama.cpp $tag"
  fetch "https://github.com/ggml-org/llama.cpp/releases/download/$tag/llama-$tag-bin-ubuntu-x64.tar.gz" \
        "$BUNDLE/llama-$tag-bin-ubuntu-x64.tar.gz"
fi

# ---------- 3. pi(用刚下载的 node 自举 npm,打成自包含 bundle)----------
if [ -f "$BUNDLE/pi-bundle.tar.gz" ]; then
  log "pi bundle 已存在,跳过"
else
  log "自举 node 打包 pi(npmmirror)…"
  rm -rf "$ROOT/.tools" && mkdir -p "$ROOT/.tools/stage"
  tar -xJf "$NODE_TAR" -C "$ROOT/.tools"
  export PATH="$(echo "$ROOT"/.tools/node-v*/bin):$PATH"
  ( cd "$ROOT/.tools/stage" \
    && npm init -y >/dev/null \
    && npm install --omit=dev --no-audit --no-fund --ignore-scripts \
         --registry="$NPM_REGISTRY" "$PI_PKG@latest" )
  node -e 'console.log("pi 版本:", require(process.argv[1] + "/package.json").version)' \
    "$ROOT/.tools/stage/node_modules/$PI_PKG" | tee "$BUNDLE/pi-version.txt"
  # 原子产出:tar 中断不会留下残缺 bundle
  tar -czf "$BUNDLE/pi-bundle.tar.gz.part" -C "$ROOT/.tools/stage" \
    node_modules package.json package-lock.json
  mv "$BUNDLE/pi-bundle.tar.gz.part" "$BUNDLE/pi-bundle.tar.gz"
fi

# ---------- 4. 模型 GGUF(HF 镜像 bartowski 量化,llama.cpp 官方转换器产出)----------
# ⚠️ 不要改回 Ollama registry 的 qwen3.5 GGUF:其 rope.dimension_sections 是 3 段约定,
#    而 llama.cpp 加载器预期 4 段,报 "wrong array length; expected 4, got 3"(2026-09-11 实测)。
#    bartowski 的 GGUF 用 llama.cpp 官方 convert_hf_to_gguf.py 产出,与加载器约定一致。
hf_model() { # hf_model <repo> <HF文件名> <本地文件名>
  local repo="$1" file="$2" out="$BUNDLE/$3"
  if [ -f "$out" ]; then log "$3 已存在,跳过"; return 0; fi
  log "下载 $file($repo,经 hf-mirror)…"
  fetch "https://hf-mirror.com/$repo/resolve/main/$file" "$out"
}

hf_model bartowski/Qwen_Qwen3.5-2B-GGUF  Qwen_Qwen3.5-2B-Q4_K_M.gguf qwen3.5-2b.gguf
if [ "${1:-}" != "--skip-4b" ]; then
  hf_model bartowski/Qwen_Qwen3.5-4B-GGUF Qwen_Qwen3.5-4B-Q4_K_M.gguf qwen3.5-4b.gguf
fi

# ---------- 5. 校验清单 ----------
( cd "$BUNDLE" \
  && find . -maxdepth 1 -type f ! -name 'MANIFEST.sha256' ! -name '*.log' ! -name '*.part' -print0 \
   | sort -z | xargs -0 sha256sum > MANIFEST.sha256 )

log "完成。bundle/ 产物:"
ls -lh "$BUNDLE"
log "下一步:把整个目录拷到内网服务器,运行 ./install.sh"
