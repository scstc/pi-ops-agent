#!/usr/bin/env bash
# uninstall.sh —— 卸载 pi-ops-agent(install.sh 的逆操作,自包含、无残留)
# 用法: ./uninstall.sh [-y]      # -y 跳过确认(脚本/cron 用)
#
# 卸载内容:服务与 systemd 单元、~/pi-ops-agent 全部、pi 配置(优先还原安装前备份)、
#           ~/.bashrc|~/.zshrc 里的 PATH 行
# 保留内容:~/.pi/agent/sessions(会话历史)、linger 设置(可能被其他用户服务共用)
set -uo pipefail
PI_OPS_HOME="${PI_OPS_HOME:-$HOME/pi-ops-agent}"
ASSUME_YES=0
[ "${1:-}" = "-y" ] && ASSUME_YES=1

log()  { printf '\033[1;32m[uninstall]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[uninstall]\033[0m %s\n' "$*"; }

case "$PI_OPS_HOME" in ""|"/"|"$HOME"|"$HOME/") die "PI_OPS_HOME 异常:$PI_OPS_HOME,拒绝执行";; esac
[ -d "$PI_OPS_HOME" ] || warn "主目录不存在(可能已卸载过)"

# ---------- 1. 停服务、清单元 ----------
systemctl --user disable --now pi-ops-llama 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/pi-ops-llama.service"
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user unset-environment MODEL 2>/dev/null || true
if [ -f "$PI_OPS_HOME/llama.pid" ] && kill -0 "$(cat "$PI_OPS_HOME/llama.pid" 2>/dev/null)" 2>/dev/null; then
  kill "$(cat "$PI_OPS_HOME/llama.pid")" 2>/dev/null || true
fi
command -v pkill >/dev/null 2>&1 && pkill -u "$(id -un)" -f llama-server 2>/dev/null || true

# ---------- 2. 确认 ----------
if [ "$ASSUME_YES" != 1 ]; then
  printf '将删除 %s 与 pi 配置(保留会话历史),确认? [y/N] ' "$PI_OPS_HOME"
  read -r REPLY
  case "$REPLY" in y|Y) ;; *) log "已取消"; exit 0;; esac
fi

# ---------- 3. 主目录(node/llama/pi/模型/启动器/日志/key) ----------
rm -rf "$PI_OPS_HOME"
log "已删除 $PI_OPS_HOME"

# ---------- 4. pi 配置:优先还原安装前备份,否则删除我们写入的文件 ----------
PI_DIR="$HOME/.pi/agent"
restore() {
  local f="$1" b
  if ls "$f".*.bak >/dev/null 2>&1; then
    b="$(ls -t "$f".*.bak | head -1)"
    mv "$b" "$f"
    log "已还原 $f(备份:$(basename "$b"))"
  elif [ -f "$f" ]; then
    rm -f "$f"
    log "已删除 $f(无备份)"
  fi
}
restore "$PI_DIR/models.json"
restore "$PI_DIR/settings.json"
restore "$PI_DIR/SYSTEM.md"
rm -f "$PI_DIR/extensions/pi-ops-tools.ts"
log "已保留 $PI_DIR/sessions(会话历史;如需彻底清除请手动删除)"

# ---------- 5. shell rc 里的 PATH 行 ----------
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [ -f "$rc" ] || continue
  if grep -q 'pi-ops-agent/bin' "$rc" 2>/dev/null; then
    sed -i '\#pi-ops-agent/bin#d' "$rc"
    log "已清理 $rc 中的 PATH 行"
  fi
done

warn "linger 未改动(若安装时启用且无其他用户服务依赖,可执行:loginctl disable-linger $USER)"
log "卸载完成"
