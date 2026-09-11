#!/usr/bin/env bash
# env-check.sh —— pi-ops-agent 部署前置自检(单文件,零依赖,可先于安装包拷到目标机跑)
# 用法: bash env-check.sh
# 退出码: 0=满足 / 1=有不满足项(硬性) / 2=仅告警
set -uo pipefail
FAIL=0; WARN=0
line() { printf '%-26s %s\n' "$1" "$2"; }

echo "================ pi-ops-agent 环境自检 ================"

# ---- OS / 架构 ----
. /etc/os-release 2>/dev/null && line "OS" "$PRETTY_NAME" || line "OS" "未知(无 /etc/os-release)"
ARCH="$(uname -m)"
if [ "$ARCH" = "x86_64" ]; then line "架构" "✓ x86_64"
else line "架构" "✗ $ARCH(当前安装包仅 x86_64)"; FAIL=1; fi

# ---- glibc(硬性:官方 Node 22 下限 2.28)----
# 注意:不用 `| head -1 | grep` 组合——pipefail 下 head 提前关管道会触发 SIGPIPE 双输出
GLIBC="$(ldd --version 2>/dev/null | awk 'NR==1{if (match($0,/[0-9]+\.[0-9]+$/)) print substr($0,RSTART,RLENGTH)}')"
[ -n "$GLIBC" ] || GLIBC=0
if awk -v v="$GLIBC" 'BEGIN{exit !(v>=2.28)}'; then line "glibc" "✓ $GLIBC(≥2.28)"
else line "glibc" "✗ $GLIBC(<2.28,不满足 Node 22 下限)"; FAIL=1; fi

# ---- libstdc++(信息项:v26.3.3 起 llama 静态链接,不再依赖)----
CXXMAX="$(strings /usr/lib64/libstdc++.so.6 2>/dev/null | grep -oE 'GLIBCXX_3\.4\.[0-9]+' | sort -V | tail -1)"
line "libstdc++(信息)" "${CXXMAX:-未检出} —— v26.3.3+ 已静态链接,不依赖此项"

# ---- 基础命令(硬性)/ 可选命令 ----
for c in bash tar xz curl; do
  if command -v "$c" >/dev/null 2>&1; then line "命令 $c" "✓"
  else line "命令 $c" "✗ 缺失(离线安装必需)"; FAIL=1; fi
done
for c in ss systemctl timeout; do
  if command -v "$c" >/dev/null 2>&1; then line "命令 $c(可选)" "✓"
  else line "命令 $c(可选)" "⚠ 缺失(不影响安装,功能降级)"; WARN=1; fi
done

# ---- 资源(2b 档:内存 ≥4.5G 硬性/8G 舒适;磁盘 ≥5G)----
MEM="$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')"
if [ "${MEM:-0}" -ge 8000 ]; then line "内存" "✓ ${MEM}MB(2b/4b 均舒适)"
elif [ "${MEM:-0}" -ge 4500 ]; then line "内存" "~ ${MEM}MB(2b 可用,4b 偏紧)"
else line "内存" "✗ ${MEM}MB(<4500MB,2b 也跑不动)"; FAIL=1; fi
DISK="$(df -m / 2>/dev/null | awk 'NR==2{print $4}')"
if [ "${DISK:-0}" -ge 5000 ]; then line "磁盘(/ 可用)" "✓ ${DISK}MB"
else line "磁盘(/ 可用)" "✗ ${DISK}MB(<5000MB,装不下)"; FAIL=1; fi
line "CPU 核数" "$(nproc 2>/dev/null || echo '?')(推理速度随核数)"

# ---- 端口 ----
if command -v ss >/dev/null 2>&1; then
  if ss -tln 2>/dev/null | grep -q ':8787 '; then
    line "端口 8787" "⚠ 已被占用(安装器会自动顺延端口)"
  else line "端口 8787" "✓ 空闲"; fi
fi

echo "======================================================"
if [ "$FAIL" = 1 ]; then echo "结论:✗ 存在不满足项,见上(✗ 行)"; exit 1
elif [ "$WARN" = 1 ]; then echo "结论:~ 满足(有可选项告警)"; exit 2
else echo "结论:✓ 完全满足,可安装"; exit 0; fi
