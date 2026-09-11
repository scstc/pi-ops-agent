#!/usr/bin/env bash
# env-check.sh —— pi-ops-agent 部署前置自检(单文件,零依赖,可先于安装包拷到目标机跑)
# 用法: bash env-check.sh
# 退出码: 0=满足 / 1=有不满足项(硬性) / 2=仅告警
# 输出语言:终端为 UTF-8 时用中文,否则自动切 ASCII 英文(客户现场终端编码不定)
set -uo pipefail
FAIL=0; WARN=0

IS_UTF8=0
case "${LC_ALL:-${LANG:-}}" in *UTF-8*|*utf8*|*UTF8*) IS_UTF8=1 ;; esac
if [ "$IS_UTF8" = 0 ] && command -v locale >/dev/null 2>&1; then
  case "$(locale charmap 2>/dev/null)" in UTF-8|UTF8|utf-8|utf8) IS_UTF8=1 ;; esac
fi

if [ "$IS_UTF8" = 1 ]; then
  S_OK="✓"; S_BAD="✗"; S_WR="⚠"
  M_TITLE="================ pi-ops-agent 环境自检 ================"
  M_ARCH_NG="需要 x86_64(当前安装包仅 x86_64)"
  M_GLIBC_OK="(≥2.28)"
  M_GLIBC_NG="(<2.28,不满足 Node 22 下限)"
  M_CXX_INFO="—— v26.3.3+ 已静态链接,不依赖此项"
  M_CMD_NG="缺失(离线安装必需)"
  M_CMD_OPT_NG="缺失(不影响安装,功能降级)"
  M_MEM_OK="(2b/4b 均舒适)"; M_MEM_MID="(2b 可用,4b 偏紧)"; M_MEM_NG="(<4500MB,2b 也跑不动)"
  M_DISK_NG="(<5000MB,装不下)"
  M_PORT_BUSY="(安装器会自动顺延端口)"
  M_SUM_PASS="结论:✓ 完全满足,可安装"
  M_SUM_WARN="结论:~ 满足(有可选项告警)"
  M_SUM_FAIL="结论:✗ 存在不满足项,见上(✗ 行)"
  L_OS="OS"; L_ARCH="架构"; L_GLIBC="glibc"; L_CXX="libstdc++(信息)"
  L_CMD="命令"; L_CMD_OPT="命令(可选)"; L_MEM="内存"; L_DISK="磁盘(/ 可用)"
  L_CPU="CPU 核数"; L_PORT="端口 8787"; L_INFERENCE="(推理速度随核数)"
else
  S_OK="OK"; S_BAD="FAIL"; S_WR="WARN"
  M_TITLE="================ pi-ops-agent env pre-check ================"
  M_ARCH_NG="x86_64 required (current bundle is x86_64 only)"
  M_GLIBC_OK="(>=2.28)"
  M_GLIBC_NG="(<2.28, below Node 22 minimum)"
  M_CXX_INFO="-- statically linked since v26.3.3, not required"
  M_CMD_NG="missing (required for offline install)"
  M_CMD_OPT_NG="missing (optional, degraded only)"
  M_MEM_OK="(2b/4b both comfortable)"; M_MEM_MID="(2b ok, 4b tight)"; M_MEM_NG="(<4500MB, not enough even for 2b)"
  M_DISK_NG="(<5000MB, not enough)"
  M_PORT_BUSY="(installer will pick next free port)"
  M_SUM_PASS="Conclusion: PASS - all requirements met, ready to install"
  M_SUM_WARN="Conclusion: PASS (with optional warnings)"
  M_SUM_FAIL="Conclusion: FAIL - see FAIL lines above"
  L_OS="OS"; L_ARCH="Arch"; L_GLIBC="glibc"; L_CXX="libstdc++ (info)"
  L_CMD="Cmd"; L_CMD_OPT="Cmd (opt)"; L_MEM="Memory"; L_DISK="Disk (/ free)"
  L_CPU="CPU cores"; L_PORT="Port 8787"; L_INFERENCE="(inference scales with cores)"
fi
line() { printf '%-24s %s\n' "$1" "$2"; }

echo "$M_TITLE"

# ---- OS / 架构 ----
. /etc/os-release 2>/dev/null && line "$L_OS" "$PRETTY_NAME" || line "$L_OS" "unknown (no /etc/os-release)"
ARCH="$(uname -m)"
if [ "$ARCH" = "x86_64" ]; then line "$L_ARCH" "$S_OK x86_64"
else line "$L_ARCH" "$S_BAD $ARCH $M_ARCH_NG"; FAIL=1; fi

# ---- glibc(硬性:官方 Node 22 下限 2.28)----
# 注意:不用 `| head -1 | grep` 组合——pipefail 下 head 提前关管道会触发 SIGPIPE 双输出
GLIBC="$(ldd --version 2>/dev/null | awk 'NR==1{if (match($0,/[0-9]+\.[0-9]+$/)) print substr($0,RSTART,RLENGTH)}')"
[ -n "$GLIBC" ] || GLIBC=0
if awk -v v="$GLIBC" 'BEGIN{exit !(v>=2.28)}'; then line "$L_GLIBC" "$S_OK $GLIBC $M_GLIBC_OK"
else line "$L_GLIBC" "$S_BAD $GLIBC $M_GLIBC_NG"; FAIL=1; fi

# ---- libstdc++(信息项:v26.3.3 起 llama 静态链接,不再依赖)----
CXXMAX="$(strings /usr/lib64/libstdc++.so.6 2>/dev/null | grep -oE 'GLIBCXX_3\.4\.[0-9]+' | sort -V | tail -1)"
line "$L_CXX" "${CXXMAX:-N/A} $M_CXX_INFO"

# ---- 基础命令(硬性)/ 可选命令 ----
for c in bash tar xz curl; do
  if command -v "$c" >/dev/null 2>&1; then line "$L_CMD $c" "$S_OK"
  else line "$L_CMD $c" "$S_BAD $M_CMD_NG"; FAIL=1; fi
done
for c in ss systemctl timeout; do
  if command -v "$c" >/dev/null 2>&1; then line "$L_CMD_OPT $c" "$S_OK"
  else line "$L_CMD_OPT $c" "$S_WR $M_CMD_OPT_NG"; WARN=1; fi
done

# ---- 资源(2b 档:内存 ≥4.5G 硬性/8G 舒适;磁盘 ≥5G)----
MEM="$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')"
if [ "${MEM:-0}" -ge 8000 ]; then line "$L_MEM" "$S_OK ${MEM}MB $M_MEM_OK"
elif [ "${MEM:-0}" -ge 4500 ]; then line "$L_MEM" "~ ${MEM}MB $M_MEM_MID"
else line "$L_MEM" "$S_BAD ${MEM}MB $M_MEM_NG"; FAIL=1; fi
DISK="$(df -m / 2>/dev/null | awk 'NR==2{print $4}')"
if [ "${DISK:-0}" -ge 5000 ]; then line "$L_DISK" "$S_OK ${DISK}MB"
else line "$L_DISK" "$S_BAD ${DISK}MB $M_DISK_NG"; FAIL=1; fi
line "$L_CPU" "$(nproc 2>/dev/null || echo '?') $L_INFERENCE"

# ---- 端口 ----
if command -v ss >/dev/null 2>&1; then
  if ss -tln 2>/dev/null | grep -q ':8787 '; then
    line "$L_PORT" "$S_WR busy $M_PORT_BUSY"
  else line "$L_PORT" "$S_OK free"; fi
fi

echo "======================================================"
if [ "$FAIL" = 1 ]; then echo "$M_SUM_FAIL"; exit 1
elif [ "$WARN" = 1 ]; then echo "$M_SUM_WARN"; exit 2
else echo "$M_SUM_PASS"; exit 0; fi
