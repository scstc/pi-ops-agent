#!/usr/bin/env bash
# ci-build.sh —— 在目标发行版容器内构建 pi-ops-agent 离线安装包(GitHub Actions 用)。
# 与 fetch-bundle.sh(联网机本地备货,国内镜像源)的区别:
#   - llama.cpp 源码编译 → 产物天然匹配当前容器/发行版的 glibc(规避预编译包门槛漂移)
#   - 下载走官方源(GH runner 在海外)
#   - 只打默认 2b 模型,控制产物体积;打完在同一容器内跑 install.sh 冒烟
#      (容器无 systemd → 自动走 nohup 兜底分支,顺带覆盖该路径)
#
# 环境变量:LLAMA_TAG(默认 b10901)、NODE_VER(默认 22.20.0)、PI_OPS_VERSION(包版本)、
#          DISTRO_SLUG(必填,如 ubuntu-22.04)、GGUF_URL(必填)、GGUF_CACHE(可选,命中免下载)
set -euo pipefail

: "${LLAMA_TAG:=b10901}"
: "${NODE_VER:=22.20.0}"
: "${DISTRO_SLUG:?需要 DISTRO_SLUG(如 ubuntu-22.04)}"
: "${GGUF_URL:?需要 GGUF_URL}"
PI_PKG="@earendil-works/pi-coding-agent"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$ROOT/.ci-work"
BUNDLE="$ROOT/bundle"
DIST="$ROOT/dist"
rm -rf "$W" "$DIST" && mkdir -p "$W" "$DIST" "$BUNDLE"

log() { printf '\033[1;34m[ci]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[ci] 失败:\033[0m %s\n' "$*" >&2; exit 1; }
fetch() { # fetch <url> <dest>
  local tries=0
  while [ "$tries" -lt 3 ]; do
    curl -fL --retry 2 --connect-timeout 15 -o "$2.part" "$1" && { mv "$2.part" "$2"; return 0; }
    tries=$((tries + 1)); sleep 2
  done
  die "下载失败: $1"
}

# ---------- 1. 构建依赖(apt / dnf 两族) ----------
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq build-essential cmake git curl xz-utils ca-certificates >/dev/null
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y -q gcc-c++ make cmake git curl xz tar findutils procps-ng
else
  die "不认识的包管理器(仅支持 apt/dnf 系)"
fi

# ---------- 2. 源码编译 llama.cpp(钉 tag;产物匹配本容器 glibc) ----------
if [ ! -x "$W/llama.cpp/build/bin/llama-server" ]; then
  log "编译 llama.cpp $LLAMA_TAG(源码,匹配 $DISTRO_SLUG)…"
  if [ ! -d "$W/llama.cpp/.git" ]; then
    rm -rf "$W/llama.cpp"
    git clone --depth 1 --branch "$LLAMA_TAG" https://github.com/ggml-org/llama.cpp "$W/llama.cpp"
  fi
  cmake -S "$W/llama.cpp" -B "$W/llama.cpp/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_CURL=OFF >/dev/null
  cmake --build "$W/llama.cpp/build" -j"$(nproc)" >/dev/null
fi
[ -x "$W/llama.cpp/build/bin/llama-server" ] || die "llama-server 编译失败"
LLAMA_TAR="$BUNDLE/llama-$LLAMA_TAG-src-$DISTRO_SLUG-x64.tar.gz"
tar -czf "$LLAMA_TAR.part" -C "$W/llama.cpp/build/bin" .
mv "$LLAMA_TAR.part" "$LLAMA_TAR"
log "llama.cpp 打包:$(basename "$LLAMA_TAR")"

# ---------- 3. node + pi(官方源;node 自举 npm) ----------
NODE_TAR="$BUNDLE/node-v$NODE_VER-linux-x64.tar.xz"
[ -f "$NODE_TAR" ] || fetch "https://nodejs.org/dist/v$NODE_VER/node-v$NODE_VER-linux-x64.tar.xz" "$NODE_TAR"
rm -rf "$W/node" && mkdir -p "$W/node" "$W/stage"
tar -xJf "$NODE_TAR" -C "$W/node" --strip-components=1
export PATH="$W/node/bin:$PATH"
log "node $(node -v)"
( cd "$W/stage" \
  && npm init -y >/dev/null \
  && npm install --omit=dev --no-audit --no-fund --ignore-scripts "$PI_PKG@latest" )
node -e 'console.log("pi", require(process.argv[1]+"/package.json").version)' \
  "$W/stage/node_modules/$PI_PKG" | tee "$BUNDLE/pi-version.txt"
tar -czf "$BUNDLE/pi-bundle.tar.gz.part" -C "$W/stage" node_modules package.json package-lock.json
mv "$BUNDLE/pi-bundle.tar.gz.part" "$BUNDLE/pi-bundle.tar.gz"

# ---------- 4. 模型 GGUF(默认只打 2b;GGUF_CACHE 命中则免下载) ----------
if [ -n "${GGUF_CACHE:-}" ] && [ -f "$GGUF_CACHE" ]; then
  log "使用缓存模型 $(basename "$GGUF_CACHE")"
  cp "$GGUF_CACHE" "$BUNDLE/qwen3.5-2b.gguf"
else
  log "下载模型(约 1.4GB)…"
  fetch "$GGUF_URL" "$BUNDLE/qwen3.5-2b.gguf"
  if [ -n "${GGUF_CACHE:-}" ]; then
    mkdir -p "$(dirname "$GGUF_CACHE")"
    cp "$BUNDLE/qwen3.5-2b.gguf" "$GGUF_CACHE"
  fi
fi

# ---------- 5. MANIFEST ----------
( cd "$BUNDLE" \
  && find . -maxdepth 1 -type f ! -name 'MANIFEST.sha256' ! -name '*.log' ! -name '*.part' -print0 \
   | sort -z | xargs -0 sha256sum > MANIFEST.sha256 )

# ---------- 6. 外层交付包(仓库脚本 + assets + bundle) ----------
VER="${PI_OPS_VERSION:-dev}"
OUT="$DIST/pi-ops-agent-$VER-$DISTRO_SLUG-x64.tar.gz"
tar -czf "$OUT" -C "$ROOT" install.sh assets README.md LICENSE bundle
( cd "$DIST" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256" )
log "交付包:$(ls -lh "$DIST" | awk 'NR>1{print $9, $5}' | tr '\n' ' ')"

# ---------- 7. 同容器冒烟(无 systemd → 走 nohup 兜底;2 vCPU 上推理慢,放宽超时) ----------
log "冒烟:install.sh 全流程(容器内)…"
export PI_OPS_HOME="$W/smoke-home"
export PI_SMOKE_TIMEOUT="${PI_SMOKE_TIMEOUT:-480}"
cd "$ROOT" && ./install.sh
log "冒烟通过 ✓"
