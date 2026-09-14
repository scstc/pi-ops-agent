#!/usr/bin/env bash
# 从上传后的真实安装包开始，在干净运行时容器中验收。
set -euo pipefail
ARTIFACTS="$(cd "${1:?artifact directory required}" && pwd)"
MODEL_ID="${2:?model id required}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIAGNOSTICS="${CI_DIAGNOSTICS_DIR:-$ROOT/.ci-verify}"
mkdir -p "$DIAGNOSTICS"

# BEGIN ci lifecycle helper
# Stop the nohup fallback deterministically.  This CI user is created solely for
# this job, so escalating a stale recorded server from TERM to KILL is safe.
ci_stop_llama() {
  local pid_file="${1:?pid file required}" port="${2:?port required}" timeout="${CI_STOP_TIMEOUT:-15}"
  local pid state starttime='' i
  ci_pid_alive() {
    pid="$1"; [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    [[ -n "$state" && "$state" != Z* ]]
  }
  ci_pid_starttime() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }
  ci_pid_is_llama() {
    [[ "$(ps -o uid= -p "$1" 2>/dev/null | tr -d '[:space:]')" = "$(id -u)" ]] || return 1
    [[ "$(ps -o comm= -p "$1" 2>/dev/null | tr -d '[:space:]')" = llama-server ]]
  }
  ci_port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1; }
  ci_endpoint_open() { curl -s -m 1 -o /dev/null "http://127.0.0.1:$port/v1/models" 2>/dev/null; }
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  if ci_pid_alive "$pid"; then
    ci_pid_is_llama "$pid" || { echo "[verify] refusing non-llama PID $pid" >&2; return 1; }
    starttime="$(ci_pid_starttime "$pid")"
    [[ -n "$starttime" ]] || { echo "[verify] cannot identify llama PID $pid" >&2; return 1; }
    ci_pid_is_llama "$pid" && [[ "$(ci_pid_starttime "$pid")" = "$starttime" ]] && kill -TERM "$pid" 2>/dev/null || true
  fi
  for i in $(seq 1 "$timeout"); do
    ! ci_pid_alive "$pid" && ! ci_endpoint_open && ! ci_port_open && { rm -f "$pid_file"; return 0; }
    sleep 1
  done
  if ci_pid_alive "$pid"; then
    echo "[verify] llama PID $pid ignored TERM; sending KILL" >&2
    [ -n "$starttime" ] && ci_pid_is_llama "$pid" && [[ "$(ci_pid_starttime "$pid")" = "$starttime" ]] && kill -KILL "$pid" 2>/dev/null || true
  fi
  for i in $(seq 1 5); do
    ! ci_pid_alive "$pid" && ! ci_endpoint_open && ! ci_port_open && { rm -f "$pid_file"; return 0; }
    sleep 1
  done
  echo "[verify] llama did not stop: pid=${pid:-missing} port=$port" >&2
  return 1
}
# END ci lifecycle helper

dump_diagnostics() {
  {
    printf 'model=%s\n' "$MODEL_ID"
    printf 'time=%s\n' "$(date -u +%FT%TZ)"
    ps -u pi-ops-smoke -o pid=,ppid=,stat=,comm= 2>/dev/null || true
  } > "$DIAGNOSTICS/processes.txt"
  if [ -f "$VERIFY_HOME/pi-ops-agent/logs/llama.out" ]; then
    # Redact the locally generated 48-hex API key before publishing diagnostics.
    sed -E 's/[[:xdigit:]]{48}/[REDACTED]/g; s/(Bearer )[[:graph:]]+/\1[REDACTED]/g' \
      "$VERIFY_HOME/pi-ops-agent/logs/llama.out" > "$DIAGNOSTICS/llama.out"
  fi
}
RUN="$ARTIFACTS/$(basename "$(find "$ARTIFACTS" -maxdepth 1 -name '*.run' -print -quit)")"
TAR="$ARTIFACTS/$(basename "$(find "$ARTIFACTS" -maxdepth 1 -name '*.tar.gz' -print -quit)")"
(cd "$ARTIFACTS" && sha256sum -c *.sha256)
python3 "$ROOT/scripts/verify-package.py" --model "$MODEL_ID" "$RUN"
python3 "$ROOT/scripts/verify-package.py" --model "$MODEL_ID" "$TAR"
line="$(awk '/^__PI_OPS_PAYLOAD_BELOW__$/{print NR + 1; exit}' "$RUN")"
test "$(tail -n +"$line" "$RUN" | sha256sum | awk '{print $1}')" = "$(sha256sum "$TAR" | awk '{print $1}')"

# 此用户仅存在于本次一次性 CI 容器中，没有系统 Node、llama 或旧 pi 配置。
VERIFY_HOME="$ROOT/.verify-user"
on_exit() { local status=$?; dump_diagnostics || true; exit "$status"; }
trap on_exit EXIT
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
# 解压目录已经清理，再确认旧服务和端口彻底消失后才从已装启动器冷启动。
OLD_PID="$(as_user bash -c 'cat "$PI_OPS_HOME/llama.pid"')"
PORT="$(as_user env LD_LIBRARY_PATH="$INSTALLED/node/lib" "$INSTALLED/node/bin/node" -e 'const fs=require("fs"); console.log(new URL(JSON.parse(fs.readFileSync(process.argv[1])).providers["llama-cpp"].baseUrl).port)' "$VERIFY_HOME/.pi/agent/models.json")"
as_user env CI_STOP_TIMEOUT=20 bash -c "$(declare -f ci_stop_llama); ci_stop_llama \"\$PI_OPS_HOME/llama.pid\" \"$PORT\"" 2>&1 | tee -a "$DIAGNOSTICS/lifecycle.log"
as_user timeout 480 "$INSTALLED/bin/pi-ops" -p '只回复 OK' </dev/null
NEW_PID="$(as_user bash -c 'cat "$PI_OPS_HOME/llama.pid"')"
test "$NEW_PID" != "$OLD_PID"
as_user env CI_STOP_TIMEOUT=20 bash -c "$(declare -f ci_stop_llama); ci_stop_llama \"\$PI_OPS_HOME/llama.pid\" \"$PORT\"" 2>&1 | tee -a "$DIAGNOSTICS/lifecycle.log"
printf '[verify] %s: checksum, model, clean non-root install and restart passed\n' "$MODEL_ID"
