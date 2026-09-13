#!/usr/bin/env bash
# ci-build.sh —— 在目标发行版容器内构建 pi-ops-agent 离线安装包(GitHub Actions 用)。
# 与 fetch-bundle.sh(联网机本地备货,国内镜像源)的区别:
#   - llama.cpp 源码编译 → 产物天然匹配当前容器/发行版的 glibc(规避预编译包门槛漂移)
#   - 下载走官方源(GH runner 在海外)
#   - 每次只打 CI 指定的一个模型,控制产物体积;打完在同一容器内跑 install.sh 冒烟
#      (容器无 systemd → 自动走 nohup 兜底分支,顺带覆盖该路径)
#
# 环境变量:LLAMA_TAG(默认 b10901)、NODE_VER(默认 22.20.0)、PI_OPS_VERSION(包版本)、
#          DISTRO_SLUG(必填,如 ubuntu-22.04)、BUNDLE_MODEL_ID(必填,如 qwen3.5-2b)、
#          GGUF_URL(必填)、GGUF_CACHE(可选,命中免下载)
set -euo pipefail

: "${LLAMA_TAG:=b10901}"
: "${NODE_VER:=22.20.0}"
: "${DISTRO_SLUG:?需要 DISTRO_SLUG(如 ubuntu-22.04)}"
: "${BUNDLE_MODEL_ID:?需要 BUNDLE_MODEL_ID(如 qwen3.5-2b)}"
: "${GGUF_URL:?需要 GGUF_URL}"
PI_PKG="@earendil-works/pi-coding-agent"
case "$BUNDLE_MODEL_ID" in
  *[!A-Za-z0-9._-]*|'') echo "[ci] 失败:非法 BUNDLE_MODEL_ID:$BUNDLE_MODEL_ID" >&2; exit 1 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$ROOT/.ci-work"
DIST="$ROOT/dist"
# bundle 必须是本次构建专属的干净目录:同一工作目录内不同模型不能混装。
# 不使用仓库根目录的 bundle/，避免 CI 脚本误删人工备货的离线素材。
rm -rf "$W" "$DIST" && mkdir -p "$W" "$DIST"
BUNDLE="$W/bundle"
mkdir -p "$BUNDLE"

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
  # RHEL8 系(rocky8/麒麟 V10)默认 gcc 8.5:链接 std::filesystem 缺 -lstdc++fs 会挂
  # (llama.cpp 报 undefined reference to std::filesystem::*)→ 用 gcc-toolset-12。
  # 注意:toolset 不带 libstdc++ 运行库,且麒麟系统库只到 GLIBCXX_3.4.24 —— 因此
  # 编译一律 -static-libstdc++(devel 包提供静态库),彻底不依赖目标机 C++ 运行库
  dnf install -y -q gcc-toolset-12 gcc-toolset-12-libstdc++-devel \
    make cmake git curl xz tar findutils procps-ng
  # shellcheck disable=SC1091
  source /opt/rh/gcc-toolset-12/enable
else
  die "不认识的包管理器(仅支持 apt/dnf 系)"
fi
STATIC_CPP=""
if [ -d /opt/rh/gcc-toolset-12 ]; then STATIC_CPP="-static-libstdc++ -static-libgcc"; fi

# ---------- 2. 源码编译 llama.cpp(钉 tag;产物匹配本容器 glibc) ----------
if [ ! -x "$W/llama.cpp/build/bin/llama-server" ]; then
  log "编译 llama.cpp $LLAMA_TAG(源码,匹配 $DISTRO_SLUG)…"
  if [ ! -d "$W/llama.cpp/.git" ]; then
    rm -rf "$W/llama.cpp"
    git clone --depth 1 --branch "$LLAMA_TAG" https://github.com/ggml-org/llama.cpp "$W/llama.cpp"
  fi
  cmake -S "$W/llama.cpp" -B "$W/llama.cpp/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_EXE_LINKER_FLAGS="$STATIC_CPP" \
    -DCMAKE_SHARED_LINKER_FLAGS="$STATIC_CPP" \
    -DGGML_NATIVE=OFF -DGGML_CPU_ALL_VARIANTS=ON -DGGML_BACKEND_DL=ON \
    -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_CURL=OFF >/dev/null
  cmake --build "$W/llama.cpp/build" -j"$(nproc)" >/dev/null
fi
[ -x "$W/llama.cpp/build/bin/llama-server" ] || die "llama-server 编译失败"
# fail loud:kylin 档若仍动态依赖 libstdc++,目标机(麒麟 V10 仅 GLIBCXX_3.4.24)必挂
if [ -d /opt/rh/gcc-toolset-12 ]; then
  if ldd "$W/llama.cpp/build/bin/llama-server" 2>/dev/null | grep -q libstdc++; then
    die "静态链接未生效:llama-server 仍依赖系统 libstdc++(目标机会 GLIBCXX not found)"
  fi
  log "静态链接自检通过(无 libstdc++ 动态依赖)"
fi
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

# ---------- 4. 模型 GGUF(每包只含 BUNDLE_MODEL_ID;GGUF_CACHE 命中则免下载) ----------
MODEL_GGUF="$BUNDLE/$BUNDLE_MODEL_ID.gguf"
if [ -n "${GGUF_CACHE:-}" ] && [ -f "$GGUF_CACHE" ]; then
  log "使用缓存模型 $(basename "$GGUF_CACHE")"
  cp "$GGUF_CACHE" "$MODEL_GGUF"
else
  log "下载模型:$BUNDLE_MODEL_ID …"
  fetch "$GGUF_URL" "$MODEL_GGUF"
  if [ -n "${GGUF_CACHE:-}" ]; then
    mkdir -p "$(dirname "$GGUF_CACHE")"
    cp "$MODEL_GGUF" "$GGUF_CACHE"
  fi
fi
printf '%s\n' "$BUNDLE_MODEL_ID" > "$BUNDLE/default-model.txt"

# ---------- 5. MANIFEST ----------
( cd "$BUNDLE" \
  && find . -maxdepth 1 -type f ! -name 'MANIFEST.sha256' ! -name '*.log' ! -name '*.part' -print0 \
   | sort -z | xargs -0 sha256sum > MANIFEST.sha256 )

# ---------- 6. 外层交付包(仓库脚本 + assets + bundle) ----------
VER="${PI_OPS_VERSION:-dev}"
OUT="$DIST/pi-ops-agent-$VER-$DISTRO_SLUG-$BUNDLE_MODEL_ID-x64.tar.gz"
tar -czf "$OUT" -C "$ROOT" install.sh uninstall.sh env-check.sh assets README.md LICENSE -C "$W" bundle
( cd "$DIST" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256" )

# 自解压交付包:仅依赖目标机已有的 bash / tar / mktemp,解压后复用原安装器与其 MANIFEST 校验。
# 安装器退出(成功或失败)后由 trap 清理临时目录,不留下模型或脚本副本。
RUN="$DIST/pi-ops-agent-$VER-$DISTRO_SLUG-$BUNDLE_MODEL_ID-x64.run"
cat > "$RUN.part" <<'EOF'
#!/usr/bin/env bash
# pi-ops-agent self-extracting installer. Payload is the matching tar.gz package.
set -euo pipefail

payload_line="$(awk '/^__PI_OPS_PAYLOAD_BELOW__$/{print NR + 1; exit}' "$0")"
[ -n "$payload_line" ] || { echo "[pi-ops] invalid self-extracting package" >&2; exit 1; }
command -v mktemp >/dev/null 2>&1 || { echo "[pi-ops] mktemp is required" >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "[pi-ops] tar is required" >&2; exit 1; }

tmpdir="$(mktemp -d "${TMPDIR:-$HOME}/.pi-ops-install.XXXXXX")"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT INT TERM

tail -n +"$payload_line" "$0" | tar -xzf - -C "$tmpdir"
(
  cd "$tmpdir"
  set +e
  ./env-check.sh
  env_check_status=$?
  set -e
  case "$env_check_status" in
    0) ;;
    2) echo "[pi-ops] environment check has optional warnings; continuing" >&2 ;;
    *) exit "$env_check_status" ;;
  esac
  ./install.sh "$@"
)
exit 0
__PI_OPS_PAYLOAD_BELOW__
EOF
cat "$OUT" >> "$RUN.part"
mv "$RUN.part" "$RUN"
chmod 755 "$RUN"
( cd "$DIST" && sha256sum "$(basename "$RUN")" > "$(basename "$RUN").sha256" )
log "交付包:$(ls -lh "$DIST" | awk 'NR>1{print $9, $5}' | tr '\n' ' ')"

# ---------- 7. 同容器冒烟(无 systemd → 走 nohup 兜底;2 vCPU 上推理慢,放宽超时) ----------
log "冒烟:install.sh 全流程(容器内)…"
export PI_OPS_HOME="$W/smoke-home"
export PI_SMOKE_TIMEOUT="${PI_SMOKE_TIMEOUT:-480}"
bash "$RUN"
log "冒烟通过 ✓"
