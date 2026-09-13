#!/usr/bin/env bash
# 从上传后的真实安装包开始，在干净运行时容器中验收。
set -euo pipefail
ARTIFACTS="$(cd "${1:?artifact directory required}" && pwd)"
MODEL_ID="${2:?model id required}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ARTIFACTS/$(basename "$(find "$ARTIFACTS" -maxdepth 1 -name '*.run' -print -quit)")"
TAR="$ARTIFACTS/$(basename "$(find "$ARTIFACTS" -maxdepth 1 -name '*.tar.gz' -print -quit)")"
(cd "$ARTIFACTS" && sha256sum -c *.sha256)
python3 "$ROOT/scripts/verify-package.py" --model "$MODEL_ID" "$RUN"
python3 "$ROOT/scripts/verify-package.py" --model "$MODEL_ID" "$TAR"
line="$(awk '/^__PI_OPS_PAYLOAD_BELOW__$/{print NR + 1; exit}' "$RUN")"
test "$(tail -n +"$line" "$RUN" | sha256sum | awk '{print $1}')" = "$(sha256sum "$TAR" | awk '{print $1}')"

# 此用户仅存在于本次一次性 CI 容器中，没有系统 Node、llama 或旧 pi 配置。
VERIFY_HOME="$ROOT/.verify-user"
useradd --create-home --home-dir "$VERIFY_HOME" pi-ops-smoke
as_user() {
  runuser -u pi-ops-smoke -- env -i HOME="$VERIFY_HOME" USER=pi-ops-smoke LANG=C.UTF-8 \
    PATH=/usr/local/bin:/usr/bin:/bin PI_OPS_HOME="$VERIFY_HOME/pi-ops-agent" \
    PI_SMOKE_TIMEOUT=480 "$@"
}
as_user bash -c 'test "$(id -u)" != 0; ! command -v node; ! command -v llama-server'
as_user bash "$RUN"
INSTALLED="$VERIFY_HOME/pi-ops-agent"
test -x "$INSTALLED/node/bin/node"
test -f "$INSTALLED/node/lib/libstdc++.so.6"
test -f "$INSTALLED/node/lib/libgcc_s.so.1"
test -x "$INSTALLED/llama/llama-server"
test ! -e "$VERIFY_HOME/.pi-ops-install.XXXXXX"
test -z "$(find "$VERIFY_HOME" -maxdepth 1 -name '.pi-ops-install.*' -print -quit)"
if grep -E '\.ci-work|\.pi-ops-install\.' "$INSTALLED/bin/pi-ops" "$INSTALLED/bin/llama-run"; then
  echo 'Installed launcher depends on a temporary build/extraction directory' >&2
  exit 1
fi
as_user env LD_LIBRARY_PATH="$INSTALLED/node/lib" "$INSTALLED/node/bin/node" -e '
  const fs=require("fs"),p=process.argv[1],model=process.argv[2];
  if(JSON.parse(fs.readFileSync(p,"utf8")).defaultModel!==model) process.exit(1);
' "$VERIFY_HOME/.pi/agent/settings.json" "$MODEL_ID"
for binary in "$INSTALLED/node/bin/node" "$INSTALLED/llama/llama-server" "$INSTALLED/llama/"*.so; do
  dependencies="$(LD_LIBRARY_PATH="$INSTALLED/node/lib:$INSTALLED/llama" ldd "$binary")"
  if printf '%s\n' "$dependencies" | grep -q 'not found'; then
    printf '%s\n' "$dependencies" >&2
    exit 1
  fi
done
# 解压目录已经清理，再停掉模型并从已装启动器重新冷启动。
as_user bash -c 'kill "$(cat "$PI_OPS_HOME/llama.pid")"; sleep 2'
as_user timeout 480 "$INSTALLED/bin/pi-ops" -p '只回复 OK' </dev/null
as_user bash -c 'kill "$(cat "$PI_OPS_HOME/llama.pid")"'
printf '[verify] %s: checksum, model, clean non-root install and restart passed\n' "$MODEL_ID"
