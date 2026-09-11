#!/usr/bin/env bash
# eval-ops.sh —— 用 5 个真实运维任务测当前默认模型的多轮成功率(Roadmap A/B 项)
# 用法: ./eval-ops.sh [模型id]     # 缺省用 settings.json 里的默认模型
# 输出: tests/out-<模型id>-<时间戳>/ 下每题的完整问答记录 + 汇总
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL="${1:-}"
PI_OPS="${PI_OPS_HOME:-$HOME/pi-ops-agent}/bin/pi-ops"
[ -x "$PI_OPS" ] || { echo "未找到 $PI_OPS,先跑 ./install.sh"; exit 1; }

TS="$(date +%Y%m%d-%H%M%S)"
ID="${MODEL:-default}"
OUT="$ROOT/tests/out-$ID-$TS"
mkdir -p "$OUT"

# 每题:名称 + 提示词(设计意图:覆盖 只读工具/裸bash/多步/判断)
tasks=(
  "disk|查看磁盘各分区用量,指出使用率最高的分区和具体百分比"
  "service|查看 sshd 服务当前是否在运行,给出结论和依据"
  "biglog|找出 /var/log 下体积最大的 3 个文件,按大小排序给出路径和体积"
  "memtop|列出当前内存占用前 5 的进程,给出 PID、进程名和内存占用"
  "port8080|查看 8080 端口被哪个进程占用并报告;若查不到要说明原因"
)

pass=0; total=0
for t in "${tasks[@]}"; do
  name="${t%%|*}"; prompt="${t#*|}"
  total=$((total + 1))
  echo "===== [$name] $prompt"
  f="$OUT/$name.txt"
  # -p 模式等待 stdin EOF,非交互必须显式关闭
  if timeout 300 "$PI_OPS" ${MODEL:+--model "llama-cpp/$MODEL"} -p "$prompt" < /dev/null \
      | tee "$f"; then
    # 粗判:回答非空且含关键迹象(人工复核以文件为准)
    if [ -s "$f" ] && grep -qiE "[0-9]|运行|占用|监听|不存在|未找到" "$f"; then
      pass=$((pass + 1)); echo "--- [$name] 粗判通过"
    else
      echo "--- [$name] 粗判存疑(输出缺关键迹象),人工复核 $f"
    fi
  else
    echo "--- [$name] 失败/超时,详见 $f"
  fi
done

echo ""
echo "汇总: $pass/$total 粗判通过;完整记录在 $OUT"
