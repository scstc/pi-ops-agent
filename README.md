# pi-ops-agent

内网(air-gapped)离线部署运维 Agent:基于 [pi](https://pi.dev) + 本地 Qwen 小模型(llama.cpp 直跑 GGUF),打包成**免联网、不需要 root、装完零手动配置**的离线交付包,跑在无法访问互联网的内网/客户现场服务器上。

- **真离线**:安装全程零外联(实测采样验证);自带 Node/llama.cpp/pi/模型,不用包管理器
- **真机已验证**:麒麟 V10(信创)全新安装全绿(v26.3.4),WSL PoC 全流程
- **安全**:危险命令审批门(headless 默认拒)+ 敏感路径写入门 + 本机 api-key
- **开箱即用**:装完自动配好一切,`pi-ops` 直接用;另附部署验证(`pi-ops-verify`)、环境自检、卸载

> **版本号规范:`年份.季度.发布序号`**(当前 **v26.3.4** = 2026 Q3 第 4 个发布)。打 `v*` tag 触发 CI 构建双档离线包并自动挂 [GitHub Release](https://github.com/scstc/pi-ops-agent/releases)。

## 目标环境与兼容性

| 维度 | 要求 | 说明 |
|---|---|---|
| 架构 | x86_64 | 当前安装包仅 x64 |
| glibc | **≥ 2.28** | 官方 Node 22 硬下限(兼容下限,更老的 CentOS 7 需非官方 Node) |
| libstdc++ | **无要求** | CI 产物静态链接 C++ 运行库(v26.3.2+,信创机系统库过老也不受影响) |
| CPU 指令集 | **无要求** | 多后端运行时分发(GGML_CPU_ALL_VARIANTS),按 CPU 自动选最优 kernel(v26.3.4+) |
| 基础命令 | bash / tar / xz / curl | 其余全部自带;ss/systemctl 缺失仅降级不阻断 |
| 资源(2b 档) | 内存 ≥4.5G(8G 舒适)/ 磁盘 ≥5G | 实测:llama-server 常驻 3.2G,空闲 CPU≈0;pi 按需 117MB 峰值 |

**已验证发行版**:麒麟 V10(Halberd/Lance)、Ubuntu 22.04/24.04、WSL Ubuntu;`kylin-v10` 档同时覆盖 RHEL/CentOS 8 系与统信 UOS 服务器版(RHEL8 血统)。

> 信创踩坑记录(glibc 之外还有两条独立兼容轴,均已修复固化):①麒麟系统 libstdc++ 只到 GLIBCXX_3.4.24 → 静态链接;②GGML_NATIVE 按 CI 机型 CPU 编译出的 kernel 含目标机没有的 AVX-512 新扩展 → SIGILL → 关 native + 多后端分发。详见 git log(v26.3.2~v26.3.4)。

## 快速开始

### 路径 A:直接用 Release 离线包(推荐,交付现场)

```bash
# 联网机下载(或浏览器到 Releases 页)
gh release download v26.3.4 -R scstc/pi-ops-agent -p "pi-ops-agent-v26.3.4-kylin-v10-x64.tar.gz*"
# 拷到内网服务器(U盘/scp),然后:
tar xzf pi-ops-agent-v26.3.4-kylin-v10-x64.tar.gz -C pi-ops
cd pi-ops
bash env-check.sh     # ① 前置自检:OS/架构/glibc/基件/内存磁盘/端口,零依赖单文件
./install.sh          # ② 依次检测,缺什么离线装什么;自动配置、起服务、四重冒烟
pi-ops                # ③ 装完即用
```

### 路径 B:源码备货(国内网络,联网 Linux 机)

```bash
./fetch-bundle.sh        # npmmirror + github + hf-mirror 三源备齐 bundle/(附 MANIFEST)
# 之后同样拷整个目录进内网,env-check → install
```

> 两条路径产物结构一致,`install.sh` 通吃;差异是 llama.cpp 来源(CI 源码编译 vs 官方预编译)与模型档(Release 包默认只带 2b,fetch-bundle 可选 4b)。

### 安装器行为(零手动配置的来源)

检测顺序(每步:系统已有且版本满足 → 复用,否则从 bundle/ 离线装):**Node ≥22.19**(私有目录,不碰系统 node)→ **llama-server** → **GGUF 模型**(默认 qwen3.5-2b)→ **pi**(自包含 bundle)。随后自动写 `~/.pi/agent/` 配置(provider 指向 `127.0.0.1:8787`、默认模型、SYSTEM.md 运维提示词、审批门扩展),起服务(systemd `--user` + linger,不可用则 nohup 兜底),跑四重冒烟(chat+api-key / pi 端到端 / **审批门实测拦截危险删除** / GGUF magic)。

### 卸载

```bash
./uninstall.sh          # 停服务清单元 → 删 ~/pi-ops-agent → pi 配置还原安装前备份 → 清 rc PATH
                         # 保留会话历史;-y 跳过确认(真机验证过全清)
```

## 指令一览

| 指令 | 用途 |
|---|---|
| `pi-ops` | 交互 TUI;`/quit` 退出 |
| `pi-ops -p "查一下磁盘"` | 单次问答(headless) |
| `pi-ops --model llama-cpp/qwen3.5-4b` | 切模型(临时);改默认编辑 `~/.pi/agent/settings.json` |
| `pi-ops-verify 部署架构.md` | 部署验证(见下节);退出码带失败数,可挂 cron 告警 |
| `bash env-check.sh` | 部署前置自检 |
| `./uninstall.sh [-y]` | 卸载 |
| `systemctl --user status pi-ops-llama` | 服务管理(无 systemd 时 `~/pi-ops-agent/bin/llama-run &`) |
| `echo 0 > ~/pi-ops-agent/idle-min` | **模型生命周期**:`0` = pi 退出即停;`5`(默认)= 空闲 5 分钟自动回收;大数值 = 常驻 |
| `MODEL=~/pi-ops-agent/models/xx.gguf` 重启服务 | 服务端换模型(A/B 用) |

临时切服务端模型:`systemctl --user set-environment MODEL=$HOME/pi-ops-agent/models/qwen3.5-4b.gguf && systemctl --user restart pi-ops-llama`(重装会自动归位默认模型)。

## 总体架构

```
┌─ 内网服务器(无互联网;无 root 也可)────────────────────┐
│ ~/pi-ops-agent/                                          │
│   bin/llama-run    llama-server -m models/*.gguf --jinja │ 模型层(OpenAI 兼容 :8787,带 api-key)
│   bin/pi-ops       PI_OFFLINE=1 → pi                     │ agent 层(按需进程,答完即退)
│   node/ llama/ pi/ models/ lib/                          │ 各组件本体(全部自带)
│ ~/.pi/agent/                                             │
│   models.json / settings.json / SYSTEM.md                │ pi 配置(install 自动生成)
│   extensions/pi-ops-tools.ts                             │ 审批门 + 只读运维工具
│ 服务:systemd --user + linger(登出不死);nohup 兜底     │
│ 模型:pi-ops 按需拉起,空闲自动回收(默认 5 分钟,       │
│       idle-min 可调;退出即停设 0)——不占常驻内存      │
└──────────────────────────────────────────────────────────┘
```

**不用 Ollama,llama.cpp 直接跑 GGUF**:无 daemon / 无 registry / 无版本检查,最贴离线交付形态。工具调用 `--jinja`、上下文 `-c 16384` 均在 `llama-run` 固化(避免默认 4K 截断工具 schema 的经典坑);crash 时 `LimitCORE=0` 防 core dump 砸盘。

## 部署验证:pi-ops-verify(架构文档驱动)

给一份部署架构文档(wiki 导出的 Markdown 即可),一条指令自动逐项核对实际部署状态并出报告:

```bash
pi-ops-verify 部署架构.md              # 报告存 verify-report-<时间戳>.md
pi-ops-verify 部署架构.md my-report.md # 指定报告文件
```

**防幻觉架构(确定性实测层)**:文档含 ` ```deploy-spec ` YAML 块时(规范见 `examples/deploy-spec-example.md`,覆盖 服务/端口/进程/单元/健康/目录/文件/版本/连通性),由 `lib/verify-check.js` 用 ss/pgrep/systemctl/curl/fs/net **确定性探测**生成"模型不可篡改"的实测表,agent 只做对照判定与汇总——小模型想编证据也没得编(实测曾抓出"模型谎称端口监听"的案例)。无 spec 块则 agent 通读全文自由理解(wiki 随手贴可用,建议配 4b)。全程只读,危险命令照被审批门拦。

## 安全模型(pi 的特殊性)

pi 没有任何内置审批弹窗——bash 以运行用户权限直接执行。本仓库用扩展补多层防线:

- **危险命令审批门**(`assets/extensions/ops-tools.ts`,语义化判定、经对抗评审多轮绕过测试):rm 分离/合并/长旗标 r+f、关机组、块设备覆写(dd of=/tee/shred/mkfs/find -delete 等)、写 `/etc` 与 `~/.ssh`、下载即执行(curl|sh 全变形含 `| sudo bash`、`bash <(curl)`)、systemctl 只放行读动词、防火墙写操作;headless 下无法交互时**默认拒绝**。安装冒烟内置实测(诱导 rm -rf → 断言目录未删)
- **写类工具门**:write/edit 写敏感路径(~/.ssh、systemd 用户单元、/etc、shell 配置)同样要求确认,堵"绕过 bash 直写持久化入口"
- **llama-server api-key**:仅绑 127.0.0.1 且带 key(`~/pi-ops-agent/llama.key`,600),防本机其他进程免鉴权调用
- **bundle 完整性**:MANIFEST sha256 校验 + 清单外文件拒绝
- 以上均为 best-effort 纵深防御,**不是沙箱**;生产建议叠加专用低权限用户/容器隔离

## 模型选型与评测

| 档位 | 打包体积 | 常驻内存 | 角色 |
|---|---|---|---|
| **qwen3.5-2b(默认)** | 1.4G(bartowski Q4_K_M) | **3.2G** 实测 | 资源受限场景的主档 |
| qwen3.5-4b(备选) | 3.0G | ~5G 实测 | 答案深度更扎实,12G+ 内存推荐 |
| Qwen3-30B-A3B 类 MoE | ~19G | 24-32G | 后续升级位(MoE 每 token 仅激活 3.3B,CPU 也快) |

5 个真实运维任务 A/B(WSL 纯 CPU):**2b 干净两轮 5/5**(port8080 能定位 docker-proxy+PID,归因浅、偶有小幻觉);**4b 5/5+4/5**(容器级归因、连 llama-server 自身资源占用都观察到)。两家都有偶发超时波动(多轮长上下文受 CPU prompt 重处理制约);差异在答案深度。跑分脚本:`tests/eval-ops.sh [模型id]`。

选型调研依据(2026-09,均有出处):2B 级多轮工具调用衰退明显(0.6B 单轮 84% → 5 轮 42%;3-4B 工具选择 F1 0.72-0.73 vs 8B 0.92);⚠️ 模型源必须用 bartowski 等 llama.cpp 官方转换器产出——Ollama registry 的 qwen3.5 GGUF 与加载器存在 rope 段数约定错配(`expected 4, got 3`),实测不可用。

## CI 与发布(GitHub Actions)

`.github/workflows/build-bundles.yml`:push main / 打 `v*` tag / 手动触发 → 双档并行:

| 目标档 | 构建基座 | 兼容 |
|---|---|---|
| `ubuntu-22.04` | ubuntu:22.04 | Ubuntu 22.04/24.04(需 20.04 则基座替换) |
| `kylin-v10` | rockylinux:8(麒麟无公开容器镜像,用同为 RHEL8 血统 glibc 2.28 的基座) | **麒麟 V10**、RHEL/CentOS 8 系、统信 UOS 服务器版 |

- 目标容器内**源码编译 llama.cpp**(钉 `LLAMA_TAG`;静态 C++ 运行库 + 多 CPU 后端 + `ldd` 自检 fail-loud),组装含 2b 的完整离线包(~1.4G),同容器跑 `install.sh` 全流程冒烟(顺带覆盖 nohup 兜底路径)
- 产物:artifact `bundle-<distro>`(7 天)+ `v*` tag 自动挂 Release(含 sha256)
- 技术栈:pi(`@earendil-works/pi-coding-agent`,MIT;⚠️ 旧 `@mariozechner` scope 已废弃)/ llama.cpp / node 22(自带,不碰系统)

## 已知限制

- **MANIFEST 信任锚点是备货的联网机**(自算无签名,只防搬运损坏,不防源头投毒);高安全场景需加 GPG 签名与上游哈希钉版(Roadmap)
- 无 spec 块的自由文档验证模式,小模型可靠性有限(建议配 4b 或补 spec 块)
- 多轮长上下文任务在纯 CPU 下有偶发超时(prompt 重处理 ~150 tok/s);可选缓解:更小 `-c`、4b/更小量化
- 当前仅 x86_64;ARM(如麒麟 Sword)需加 arm64 构建档

## Roadmap

- [x] WSL PoC 全流程(2026-09-11)
- [x] 运维骨架:SYSTEM.md + 只读工具 + 审批门实测(2026-09-11)
- [x] 2b/4b 五任务 A/B 实测(2026-09-11)
- [x] CI 双档离线包 + Release 自动发布(版本 26.3.x)(2026-09-11)
- [x] 部署验证 pi-ops-verify(确定性实测层防幻觉)(2026-09-11)
- [x] env-check / uninstall(2026-09-11)
- [x] **麒麟 V10 真机交付闭环:全新安装全绿、零外联实测**(v26.3.4,2026-09-11)
- [ ] 上游产物钉版 + 哈希固定(签名链)
- [ ] 可选:pi 官方 `build-binaries.sh --offline-model-data` 单二进制形态对比
- [ ] 可选:arm64 档(麒麟 Sword)/ skills 目录预置(运维 SOP)/ pi-mcp-adapter 离线化

## 参考

- [pi 官网与文档](https://pi.dev) / [earendil-works/pi 仓库](https://github.com/earendil-works/pi)
- [llama.cpp function-calling 文档](https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md)
- [bartowski Qwen3.5 GGUF](https://huggingface.co/bartowski/Qwen_Qwen3.5-2B-GGUF)(模型源;Ollama registry 的同款不可用于 llama.cpp)
- [Docker: 本地 LLM 工具调用实测](https://www.docker.com/blog/local-llm-tool-calling-a-practical-evaluation/)
- [Qwen3 技术报告](https://arxiv.org/html/2505.09388v1)

## License

[MIT](./LICENSE)
