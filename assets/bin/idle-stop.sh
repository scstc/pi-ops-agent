#!/usr/bin/env bash
# idle-stop.sh —— 模型服务空闲回收(systemd user timer 每分钟调用;无 systemd 时可挂 cron)
# 策略:.last-use 标记超过 idle-min 分钟 → 停掉 llama-server,释放常驻内存
# idle-min 文件($PI_OPS_HOME/idle-min):默认 5;0 = 由 pi-ops 退出时直接停(本脚本跳过)
PI_OPS_HOME="${PI_OPS_HOME:-$HOME/pi-ops-agent}"
MARKER="$PI_OPS_HOME/.last-use"
IDLE="$(cat "$PI_OPS_HOME/idle-min" 2>/dev/null || echo 5)"
case "$IDLE" in ''|*[!0-9]*) IDLE=5 ;; esac
[ "$IDLE" = "0" ] && exit 0

active() {
  systemctl --user is-active --quiet pi-ops-llama 2>/dev/null && return 0
  [ -f "$PI_OPS_HOME/llama.pid" ] && kill -0 "$(cat "$PI_OPS_HOME/llama.pid" 2>/dev/null)" 2>/dev/null
}
active || exit 0
[ -f "$MARKER" ] || exit 0

AGE=$(( $(date +%s) - $(stat -c %Y "$MARKER") ))
[ "$AGE" -ge $((IDLE * 60)) ] || exit 0

systemctl --user stop pi-ops-llama 2>/dev/null \
  || kill "$(cat "$PI_OPS_HOME/llama.pid" 2>/dev/null)" 2>/dev/null || true
rm -f "$PI_OPS_HOME/llama.pid"
