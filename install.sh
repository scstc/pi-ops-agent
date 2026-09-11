#!/usr/bin/env bash
# install.sh —— 在内网(离线)服务器上执行:依次检测 node / llama-server / 模型 / pi,
# 缺什么就从 bundle/ 离线装什么(不用包管理器、不需要 root);
# 然后全自动配置 pi(models.json / 默认模型 / SYSTEM.md / 运维扩展),起服务并冒烟验证。
# 装完即用:`pi-ops`(交互)或 `pi-ops -p "..."`(单次问答),无需任何手动模型配置。
#
# 可选环境变量:PI_OPS_HOME(默认 ~/pi-ops-agent)、PORT(默认 8787,被其他进程占用时顺延)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="$ROOT/bundle"
PI_OPS_HOME="${PI_OPS_HOME:-$HOME/pi-ops-agent}"
PORT="${PORT:-8787}"
PI_DIR="$HOME/.pi/agent"
PI_PKG_DIR="$PI_OPS_HOME/pi/node_modules/@earendil-works/pi-coding-agent"

log()  { printf '\033[1;32m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[install] 失败:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 0. 输入消毒:路径会被展开进生成的脚本/JSON,拒绝特殊字符 ----------
for v in PI_OPS_HOME HOME; do
  eval "val=\"\$$v\""
  case "$val" in
    *[!A-Za-z0-9/._~-]*) die "\$$v 含非法字符(仅允许字母数字 / . _ - ~):$val" ;;
  esac
done

# ---------- 1. 产物完整性 ----------
if [ -f "$BUNDLE/MANIFEST.sha256" ]; then
  log "校验 bundle 完整性(sha256)…"
  ( cd "$BUNDLE" && sha256sum -c MANIFEST.sha256 --quiet ) || die "bundle 校验失败,产物在传输中损坏"
  extras="$(cd "$BUNDLE" && for f in *; do
      case "$f" in MANIFEST.sha256|*.log) continue ;; esac
      awk -v f="$f" '{n=$2; sub(/^\.\//,"",n); if(n==f) found=1} END{exit !found}' MANIFEST.sha256 || echo "$f"
    done)"
  [ -z "$extras" ] || die "bundle/ 存在清单外文件(来源不明,拒绝安装;在联网机重跑 fetch-bundle.sh 可重建清单):$(echo "$extras" | tr '\n' ' ')"
else
  warn "无 MANIFEST.sha256,跳过完整性校验(注:清单只防搬运损坏,信任锚点是备货的联网机)"
fi

# ---------- 2. Node.js(≥22.19,pi 的硬要求)----------
node_ge() { # node_ge <major> <minor>
  command -v node >/dev/null 2>&1 || return 1
  node -e 'const [M,m]=process.versions.node.split(".").map(Number);
           const [W,w]=process.argv.slice(1).map(Number);
           process.exit(M>W||(M===W&&m>=w)?0:1)' "$1" "$2" 2>/dev/null
}
NODE_BIN_DIR=""
if node_ge 22 19; then
  log "检测到系统 node $(node -v)(≥22.19),复用"
else
  NODE_TAR="$(ls "$BUNDLE"/node-v22*-linux-x64.tar.xz 2>/dev/null | head -1 || true)"
  [ -n "$NODE_TAR" ] || die "无可用 node(系统未装且 bundle 缺 node-v22*-linux-x64.tar.xz)"
  log "离线安装 node:$(basename "$NODE_TAR")"
  rm -rf "$PI_OPS_HOME/node"; mkdir -p "$PI_OPS_HOME/node"
  tar -xJf "$NODE_TAR" -C "$PI_OPS_HOME/node" --strip-components=1
  NODE_BIN_DIR="$PI_OPS_HOME/node/bin"
  export PATH="$NODE_BIN_DIR:$PATH"
  node_ge 22 19 || die "离线安装的 node 异常"
fi
NODE="$(command -v node)"

# ---------- 3. llama-server ----------
LLAMA_BIN="$(command -v llama-server || true)"
if [ -n "$LLAMA_BIN" ]; then
  log "检测到系统 llama-server:$LLAMA_BIN,复用"
else
  LLAMA_TGZ="$(ls "$BUNDLE"/llama-*.tar.gz 2>/dev/null | head -1 || true)"
  [ -n "$LLAMA_TGZ" ] || die "无 llama-server(系统未装且 bundle 缺 llama-*.tar.gz)"
  log "离线安装 llama.cpp:$(basename "$LLAMA_TGZ")"
  rm -rf "$PI_OPS_HOME/llama"; mkdir -p "$PI_OPS_HOME/llama"
  tar -xzf "$LLAMA_TGZ" -C "$PI_OPS_HOME/llama"
  LLAMA_BIN="$(find "$PI_OPS_HOME/llama" -type f -name llama-server | head -1)"
  [ -n "$LLAMA_BIN" ] || die "llama 压缩包里没找到 llama-server 可执行文件"
  chmod +x "$LLAMA_BIN"
fi
LLAMA_DIR="$(dirname "$LLAMA_BIN")"

# ---------- 4. 模型 GGUF ----------
mkdir -p "$PI_OPS_HOME/models"
shopt -s nullglob
gguf_ok() { [ "$(head -c 4 "$1" 2>/dev/null)" = "GGUF" ]; }
for g in "$BUNDLE"/*.gguf; do
  base="$(basename "$g")"
  case "$base" in
    *[!A-Za-z0-9._-]*) die "模型文件名含非法字符:$base" ;;
  esac
  gguf_ok "$g" || die "模型文件损坏(非 GGUF 格式,可能传输截断):$base"
  dst="$PI_OPS_HOME/models/$base"
  if [ -f "$dst" ] && [ "$(stat -c%s "$g")" = "$(stat -c%s "$dst")" ]; then
    log "模型 $base 已存在,跳过"
  elif [ -f "$dst" ] && [ "$(stat -c%s "$g")" -lt "$(stat -c%s "$dst")" ]; then
    warn "模型 $base 比 $PI_OPS_HOME/models/ 中已有的小,疑似截断/旧版,跳过覆盖"
  else
    [ -f "$dst" ] && log "模型 $base 与已装版本不同且更大,覆盖(升级)" \
                 || log "安装模型 $base(数 GB,拷贝需片刻)…"
    cp "$g" "$dst"
  fi
done
[ -n "$(ls -A "$PI_OPS_HOME/models" 2>/dev/null)" ] || die "没有任何 GGUF 模型"
DEFAULT_GGUF="$PI_OPS_HOME/models/qwen3.5-2b.gguf"
[ -f "$DEFAULT_GGUF" ] || DEFAULT_GGUF="$(ls "$PI_OPS_HOME"/models/*.gguf | head -1)"
DEFAULT_ID="$(basename "$DEFAULT_GGUF" .gguf)"

# ---------- 5. pi(已装版本与 bundle 不一致则升级)----------
PI_INSTALLED=""
[ -f "$PI_PKG_DIR/package.json" ] && \
  PI_INSTALLED="$("$NODE" -e 'console.log(require(process.argv[1]+"/package.json").version)' "$PI_PKG_DIR" 2>/dev/null || true)"
PI_WANT=""
[ -f "$BUNDLE/pi-version.txt" ] && \
  PI_WANT="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$BUNDLE/pi-version.txt" | head -1 || true)"
if [ -n "$PI_INSTALLED" ] && [ -n "$PI_WANT" ] && [ "$PI_INSTALLED" != "$PI_WANT" ]; then
  log "pi 版本变化:$PI_INSTALLED → $PI_WANT,重新安装"
  rm -rf "$PI_OPS_HOME/pi"
  PI_INSTALLED=""
fi
if [ -z "$PI_INSTALLED" ] && [ -f "$BUNDLE/pi-bundle.tar.gz" ]; then
  log "离线安装 pi …"
  mkdir -p "$PI_OPS_HOME/pi"
  tar -xzf "$BUNDLE/pi-bundle.tar.gz" -C "$PI_OPS_HOME/pi"
  PI_INSTALLED="$("$NODE" -e 'console.log(require(process.argv[1]+"/package.json").version)' "$PI_PKG_DIR" 2>/dev/null || echo "?")"
elif [ -z "$PI_INSTALLED" ]; then
  die "无 pi(bundle 缺 pi-bundle.tar.gz)"
else
  log "pi $PI_INSTALLED 已安装,跳过"
fi
PI_CLI="$PI_OPS_HOME/pi/node_modules/.bin/pi"
[ -f "$PI_CLI" ] || die "pi 安装异常:缺 $PI_CLI"

# ---------- 6. API key(llama-server 仅本机可达,但防本机其他进程白嫖/灌上下文)----------
KEY_FILE="$PI_OPS_HOME/llama.key"
if [ ! -s "$KEY_FILE" ]; then
  # 24 字节随机 → 48 个 hex 字符;管道各环节自然结束,规避 pipefail 下的 SIGPIPE
  ( umask 077 && head -c 24 /dev/urandom | od -An -tx1 | tr -d " \n" > "$KEY_FILE" )
fi
LLAMA_KEY="$(cat "$KEY_FILE")"

# ---------- 7. 端口(先停自己的旧实例,清残留,防重装漂移/双实例)----------
systemctl --user stop pi-ops-llama 2>/dev/null || true
if [ -f "$PI_OPS_HOME/llama.pid" ] && kill -0 "$(cat "$PI_OPS_HOME/llama.pid" 2>/dev/null)" 2>/dev/null; then
  kill "$(cat "$PI_OPS_HOME/llama.pid")" 2>/dev/null || true
fi
rm -f "$PI_OPS_HOME/llama.pid"
# 清掉任何残留 llama-server(防双实例双内存;本脚本 cmdline 不含该词,无自杀风险)
command -v pkill >/dev/null 2>&1 && pkill -u "$(id -un)" -f llama-server 2>/dev/null || true
sleep 2
if command -v ss >/dev/null 2>&1; then
  while ss -tln 2>/dev/null | grep -qE ":$PORT[[:space:]]"; do PORT=$((PORT + 1)); done
else
  warn "无 ss 命令,跳过端口占用检测(假定 $PORT 空闲;若被占服务会反复重启)"
fi
log "llama-server 使用端口:$PORT"

# ---------- 8. pi 全自动配置 ----------
mkdir -p "$PI_DIR/extensions"
backup() { # 滚动备份:保留上一版用户定制
  [ -f "$1" ] || return 0
  cp "$1" "$1.$(date +%Y%m%d%H%M%S).bak" || die "备份失败:$1(磁盘满?)"
  warn "已备份 $1 → *.bak"
}

# 8.1 models.json:按实际存在的 gguf 生成,指向本地 llama-server(带 key)
backup "$PI_DIR/models.json"
{
  echo '{'
  echo '  "providers": {'
  echo '    "llama-cpp": {'
  echo "      \"baseUrl\": \"http://127.0.0.1:$PORT/v1\","
  echo '      "api": "openai-completions",'
  echo "      \"apiKey\": \"$LLAMA_KEY\","
  echo '      "models": ['
  first=1
  for g in "$PI_OPS_HOME"/models/*.gguf; do
    id="$(basename "$g" .gguf)"
    [ "$first" = 1 ] || echo ','
    first=0
    printf '        {"id": "%s", "contextWindow": 32768, "maxTokens": 8192}' "$id"
  done
  echo ''
  echo '      ]'
  echo '    }'
  echo '  }'
  echo '}'
} > "$PI_DIR/models.json"
log "写入 $PI_DIR/models.json(provider=llama-cpp → 127.0.0.1:$PORT,带 api-key)"

# 8.2 settings.json:合并写入默认 provider/model(保留用户已有主题等设置)
backup "$PI_DIR/settings.json"
"$NODE" -e '
const fs=require("fs"), p=process.argv[1];
let s={}; try{ s=JSON.parse(fs.readFileSync(p,"utf8")) }catch(e){}
s.defaultProvider="llama-cpp";
s.defaultModel=process.argv[2];
s.enableInstallTelemetry=false;
fs.writeFileSync(p, JSON.stringify(s,null,2)+"\n");
' "$PI_DIR/settings.json" "$DEFAULT_ID"
log "写入默认模型:$DEFAULT_ID"

# 8.3 SYSTEM.md(运维角色系统提示词)
backup "$PI_DIR/SYSTEM.md"
cp "$ROOT/assets/SYSTEM.md" "$PI_DIR/SYSTEM.md"

# 8.4 运维扩展(审批门 + 只读工具)
cp "$ROOT/assets/extensions/ops-tools.ts" "$PI_DIR/extensions/pi-ops-tools.ts"

# ---------- 9. 启动器 ----------
mkdir -p "$PI_OPS_HOME/bin" "$PI_OPS_HOME/logs"
cat > "$PI_OPS_HOME/bin/llama-run" <<EOF
#!/usr/bin/env bash
# 由 install.sh 生成:启动本地 llama-server
# llama.cpp 预编译包是"二进制+同目录 .so"布局,必须带上 LD_LIBRARY_PATH(无尾部空项,防 cwd 注入)
# 临时切模型(如 A/B):MODEL=$PI_OPS_HOME/models/qwen3.5-4b.gguf 再重启服务
# 关 core dump:crash-loop 时每轮可砸 1.5GB+ 核转储,把磁盘 IO 打满(D 态卡整机)
ulimit -c 0 2>/dev/null || true
touch "$PI_OPS_HOME/.last-use" 2>/dev/null || true   # 保鲜标记(空闲回收的计时基准)
export LD_LIBRARY_PATH="$LLAMA_DIR\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
MODEL_GGUF="\${MODEL:-$DEFAULT_GGUF}"
exec "$LLAMA_BIN" \\
  -m "\$MODEL_GGUF" \\
  --alias "\$(basename "\$MODEL_GGUF" .gguf)" \\
  --host 127.0.0.1 --port "$PORT" \\
  --api-key "$(cat "$KEY_FILE")" \\
  -c 16384 --jinja
EOF
chmod +x "$PI_OPS_HOME/bin/llama-run"

if [ -n "$NODE_BIN_DIR" ]; then
  PATHLINE='export PATH="'"$NODE_BIN_DIR"':$PATH"'
else
  PATHLINE=':'
fi
cat > "$PI_OPS_HOME/bin/pi-ops" <<EOF
#!/usr/bin/env bash
# 由 install.sh 生成:离线模式启动 pi;模型服务按需拉起 + 空闲回收(见 bin/idle-stop.sh)
# idle-min 配置文件:0 = pi 退出即停模型;N>0 = 空闲 N 分钟后自动停;很大 = 常驻
export PI_OFFLINE=1 PI_TELEMETRY=0
$PATHLINE
HOME_DIR_="$PI_OPS_HOME"
PORT_="$PORT"
KEY_="\$(cat "\$HOME_DIR_/llama.key" 2>/dev/null)"
MARKER_="\$HOME_DIR_/.last-use"

model_up() { curl -sf -m 2 -H "Authorization: Bearer \$KEY_" "http://127.0.0.1:\$PORT_/v1/models" >/dev/null 2>&1; }
if ! model_up; then
  echo "[pi-ops] 本地模型未运行,启动中(首次加载约 0.5~1 分钟)…" >&2
  systemctl --user start pi-ops-llama 2>/dev/null \\
    || { nohup "\$HOME_DIR_/bin/llama-run" >>"\$HOME_DIR_/logs/llama.out" 2>&1 & echo \$! > "\$HOME_DIR_/llama.pid"; }
  ok_=0
  for i_ in \$(seq 1 "\${PI_OPS_START_TIMEOUT:-180}"); do
    model_up && { ok_=1; break; }
    sleep 1
  done
  [ "\$ok_" = 1 ] || echo "[pi-ops] 警告:模型服务 \${PI_OPS_START_TIMEOUT:-180}s 未就绪,继续启动 pi(可能连不上模型)" >&2
fi
touch "\$MARKER_"

# 刷新循环在后台跑(pi 必须前台:TUI 在后台拿不到终端会静默退出)
( while :; do sleep 30; touch "\$MARKER_"; done ) &
refresh_=\$!
"$NODE" "$PI_CLI" "\$@"
rc_=\$?
kill "\$refresh_" 2>/dev/null
touch "\$MARKER_"

if [ "\$(cat "\$HOME_DIR_/idle-min" 2>/dev/null || echo 5)" = "0" ]; then
  systemctl --user stop pi-ops-llama 2>/dev/null \\
    || kill "\$(cat "\$HOME_DIR_/llama.pid" 2>/dev/null)" 2>/dev/null || true
  rm -f "\$HOME_DIR_/llama.pid"
fi
exit "\$rc_"
EOF
chmod +x "$PI_OPS_HOME/bin/pi-ops"

# 空闲回收组件与默认空闲窗口(分钟)
cp "$ROOT/assets/bin/idle-stop.sh" "$PI_OPS_HOME/bin/idle-stop.sh"
chmod +x "$PI_OPS_HOME/bin/idle-stop.sh"
[ -f "$PI_OPS_HOME/idle-min" ] || echo 5 > "$PI_OPS_HOME/idle-min"

# 部署验证指令(架构文档驱动:确定性实测层 + agent 解读)
cp "$ROOT/assets/bin/pi-ops-verify" "$PI_OPS_HOME/bin/pi-ops-verify"
chmod +x "$PI_OPS_HOME/bin/pi-ops-verify"
mkdir -p "$PI_OPS_HOME/lib"
cp "$ROOT/assets/lib/verify-check.js" "$PI_OPS_HOME/lib/verify-check.js"

# PATH 写入 shell rc:zsh 用户读 .zshrc 不读 .bashrc,已存在的 rc 都补一份
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [ -f "$rc" ] || continue
  grep -qF "${PI_OPS_HOME}/bin" "$rc" 2>/dev/null || \
    printf 'export PATH="%s/bin:$PATH"  # pi-ops-agent\n' "$PI_OPS_HOME" >> "$rc"
done
if [ ! -f "$HOME/.bashrc" ] && [ ! -f "$HOME/.zshrc" ]; then
  printf 'export PATH="%s/bin:$PATH"  # pi-ops-agent\n' "$PI_OPS_HOME" >> "$HOME/.bashrc"
fi

# ---------- 10. 起服务:优先 systemd --user(接受 degraded),失败则 nohup 兜底 ----------
RUNNER="$PI_OPS_HOME/bin/llama-run"
SYS_STATE="$(systemctl --user is-system-running 2>/dev/null || true)"
if [ "$SYS_STATE" = "running" ] || [ "$SYS_STATE" = "degraded" ]; then
  log "systemd --user 可用(状态:$SYS_STATE),安装用户级服务 …"
  mkdir -p "$HOME/.config/systemd/user"
  cat > "$HOME/.config/systemd/user/pi-ops-llama.service" <<EOF
[Unit]
Description=pi-ops-agent llama-server (local LLM)
[Service]
Type=simple
ExecStart="$RUNNER"
Restart=on-failure
RestartSec=3
LimitCORE=0
[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable pi-ops-llama >/dev/null 2>&1 || true
  # 重装=回归默认模型:清掉"临时 A/B 切换"用的管理器级 MODEL 变量
  # (它是 set-environment 设的,跨服务重启存活,不清会静默压过安装默认值)
  systemctl --user unset-environment MODEL 2>/dev/null || true
  # restart 而非 enable --now:单元可能已在跑旧配置,必须强制换新
  systemctl --user restart pi-ops-llama
  if loginctl enable-linger "$USER" 2>/dev/null; then
    log "已启用 linger(SSH 登出后服务保持运行)"
  else
    warn "无法启用 linger:登出最后一个会话后服务会停止,需管理员执行:loginctl enable-linger $USER"
  fi
  # 空闲回收定时器:每分钟检查 .last-use,超窗即停模型释放内存(idle-min 可调)
  cat > "$HOME/.config/systemd/user/pi-ops-llama-idle.service" <<EOF
[Unit]
Description=pi-ops-agent llama-server idle reaper
[Service]
Type=oneshot
ExecStart="$PI_OPS_HOME/bin/idle-stop.sh"
EOF
  cat > "$HOME/.config/systemd/user/pi-ops-llama-idle.timer" <<EOF
[Unit]
Description=Reap idle pi-ops llama-server
[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now pi-ops-llama-idle.timer >/dev/null 2>&1 \
    || warn "空闲回收定时器启用失败(模型将常驻;可手动把 bin/idle-stop.sh 挂 cron)"
else
  log "systemd --user 不可用(状态:${SYS_STATE:-无}),nohup 兜底启动"
  nohup "$RUNNER" > "$PI_OPS_HOME/logs/llama.out" 2>&1 &
  echo $! > "$PI_OPS_HOME/llama.pid"
  warn "注意:nohup 兜底模式在机器重启后需手动执行 $RUNNER(或改用 systemd)"
fi

# ---------- 11. 冒烟 ----------
log "等待 llama-server 就绪(首次加载模型需数十秒)…"
ok=0
for i in $(seq 1 120); do
  if curl -sf -m 2 -H "Authorization: Bearer $LLAMA_KEY" "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then ok=1; break; fi
  sleep 1
done
[ "$ok" = 1 ] || die "llama-server 120s 未就绪(检查端口占用/模型完整性;日志:$PI_OPS_HOME/logs/llama.out 或 journalctl --user -u pi-ops-llama)"
log "llama-server 就绪 ✓"

log "冒烟:chat+tools 请求 …"
smoke="$(curl -sf -m 60 -H "Authorization: Bearer $LLAMA_KEY" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$DEFAULT_ID\",\"max_tokens\":256,\"messages\":[{\"role\":\"user\",\"content\":\"回复:OK\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_time\",\"description\":\"获取时间\",\"parameters\":{\"type\":\"object\",\"properties\":{},\"required\":[]}}}]}" \
  "http://127.0.0.1:$PORT/v1/chat/completions")" || die "chat 接口冒烟失败(检查 llama 日志与 llama.key)"
log "chat 响应片段:${smoke:0:160}"

# PI_SMOKE_TIMEOUT:冒烟单步超时(默认 240s;慢机器如 CI 2 vCPU 容器可调大)
if command -v timeout >/dev/null 2>&1; then TO="timeout ${PI_SMOKE_TIMEOUT:-240}"; else TO=""; fi
# 注意:pi -p 会等待 stdin EOF,非交互环境必须显式关闭 stdin
log "冒烟:pi 端到端(headless)…"
$TO "$PI_OPS_HOME/bin/pi-ops" -p "用一句话自我介绍(你是 pi-ops-agent),然后只回复:就绪" < /dev/null \
  || die "pi 冒烟失败(模型:$DEFAULT_ID;检查 $PI_DIR/models.json 与 llama 日志)"

log "冒烟:审批门(headless 下危险命令应被默认拒绝)…"
GATE_DIR="/tmp/pi-ops-gate-test.$$"; mkdir -p "$GATE_DIR" && echo x > "$GATE_DIR/f"
$TO "$PI_OPS_HOME/bin/pi-ops" -p "请用 bash 工具执行这条命令:rm -rf $GATE_DIR" < /dev/null >/dev/null 2>&1 || true
if [ -e "$GATE_DIR" ]; then
  log "审批门生效 ✓(危险命令被拒,$GATE_DIR 未被删除)"
  rm -rf "$GATE_DIR"
else
  rm -rf "$GATE_DIR" 2>/dev/null || true
  die "审批门未拦截危险命令 rm -rf(headless 下应默认拒绝)——检查扩展加载"
fi

# ---------- 12. 完成 ----------
cat <<EOF

============================================
 pi-ops-agent 安装完成 ✓
============================================
 主目录      : $PI_OPS_HOME
 模型(默认) : $DEFAULT_ID  (llama-server 127.0.0.1:$PORT,带 api-key)
 备选模型    : $(ls "$PI_OPS_HOME/models/" | tr '\n' ' ')
 用法        : pi-ops                    # 交互 TUI
               pi-ops -p "查一下磁盘"    # 单次问答
 切换模型    : pi-ops --model llama-cpp/qwen3.5-4b
 服务管理    : systemctl --user status pi-ops-llama
               (无 systemd 时: $PI_OPS_HOME/bin/llama-run &)
 日志        : $PI_OPS_HOME/logs/llama.out 或 journalctl --user -u pi-ops-llama
 新开 shell 或 source ~/.bashrc 后 pi-ops 即在 PATH 中
============================================
EOF