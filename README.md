# pi-ops-agent

内网(air-gapped)离线部署运维 Agent:基于 [pi](https://pi.dev) + 本地 Qwen 小模型(llama.cpp 直跑 GGUF),打包成**免联网、不需要 root、装完零手动配置**的离线交付包,跑在无法访问互联网的内网/客户现场服务器上。

> 状态:**WSL PoC 全流程跑通**(2026-09-11)——fetch-bundle 备货 → install 离线安装 → systemd 常驻(含 linger)→ chat/审批门/运维工具冒烟全过;2b/4b 已做 5 任务 A/B(见「评测结果」)。

## 快速开始

联网的 Linux x86_64 机器上备货(一次性):

```bash
./fetch-bundle.sh        # 备齐 node + llama.cpp + pi + qwen3.5-2b/4b GGUF 到 bundle/,附 sha256 清单
```

把整个目录拷进内网服务器,然后:

```bash
./install.sh             # 依次检测环境,缺什么离线装什么;自动配置 pi、起服务、冒烟验证
pi-ops                   # 装完即用(交互 TUI);或 pi-ops -p "查一下磁盘"(单次问答)
```

`install.sh` 的检测顺序(每步:系统已有且版本满足 → 复用,否则从 bundle/ 离线装):

1. **Node ≥ 22**(pi 的硬要求;npmmirror tarball,解到 `~/pi-ops-agent/node`)
2. **llama-server**(llama.cpp 官方预编译单二进制)
3. **GGUF 模型**(默认 qwen3.5-2b,备选 4b;来自 Ollama registry blob——即 `ollama pull` 的底层协议,但**运行时不用 Ollama**)
4. **pi**(npm 包自包含 bundle,含全部依赖)

装完零手动配置:自动生成 `~/.pi/agent/` 下的 `models.json`(provider 指向 `127.0.0.1:8787` 的 llama-server)、`settings.json` 默认 provider/model(保留已有主题等设置)、`SYSTEM.md` 运维提示词、`extensions/pi-ops-tools.ts`。

## 总体架构

```
┌─ 内网服务器(无互联网;无 root 也可)────────────────────┐
│ ~/pi-ops-agent/                                          │
│   bin/llama-run    llama-server -m models/*.gguf --jinja │ 模型层(OpenAI 兼容 :8787)
│   bin/pi-ops       PI_OFFLINE=1 → pi                     │ agent 层
│   node/ llama/ pi/ models/                               │ 各组件本体
│ ~/.pi/agent/                                             │
│   models.json            provider=llama-cpp → 127.0.0.1  │
│   SYSTEM.md              运维角色系统提示词              │
│   extensions/pi-ops-tools.ts   审批门 + 只读运维工具     │
│ 服务:systemd --user 优先,不可用时 nohup 兜底            │
└──────────────────────────────────────────────────────────┘
```

**不用 Ollama,llama.cpp 直接跑 GGUF**:单二进制直接加载模型文件起 OpenAI 兼容 API,无 daemon / 无 registry / 无版本检查,最贴离线交付形态;llama.cpp 也是 pi 官方文档专门列出的 provider 之一。工具调用需 `--jinja`(新版默认开,`llama-run` 已显式固化),上下文 `-c 16384`(`llama-run` 已固化,避免默认 4K 截断工具 schema 的经典坑)。

## 关键选型结论(2026-09 调研,均有出处)

### 框架:pi(`@earendil-works/pi-coding-agent`)

- MIT 许可,可打包进内部离线分发(保留版权声明即可)
- 本地模型一等公民:llama.cpp / Ollama / LM Studio / vLLM / 任意 OpenAI 兼容端点
- TS 扩展免编译(jiti 加载):可注册自定义运维工具、覆盖全部内置工具(bash/read/write…)、`SYSTEM.md` 整体替换系统提示词——"改造成运维 agent"是官方意图内的用法
- `PI_OFFLINE=1` 关闭全部启动期网络行为(版本检查/目录刷新/遥测),只剩模型端点一个网络依赖(`pi-ops` 启动器已固化)
- ⚠️ 旧 npm scope `@mariozechner/pi-coding-agent` 已废弃,钉新包名
- bun 是官方安装方式之一(pi.dev 安装区 5 tabs),但包操作路径仍默认调 npm(适配中:pi#6396),交付包不用 bun

### 模型:主用 2B,4B 备选做 A/B

| 档位 | 来源 tag | 体积 | 内存 | 角色 |
|---|---|---|---|---|
| **默认** | `qwen3.5:2b` | 2.7GB | ~4-6GB | 用户指定的主模型 |
| 备选 | `qwen3.5:4b` | 3.4GB | ~8GB | A/B 对比;多轮更稳的下限 |
| CPU-only 大内存 | Qwen3-30B-A3B 类 MoE | ~19GB | 24-32GB | 后续升级位(MoE 每 token 仅激活 3.3B,CPU 上 10-20+ tok/s) |

选型依据(调研结论):2B 级多轮工具调用会衰退(0.6B 单轮 84% → 5 轮 42%;3-4B 工具选择 F1 0.72-0.73 vs 8B 0.92);中文多约束指令 1.7B 档丢约 1/3 约束。**默认 2B 是资源受限场景的取舍**,Roadmap 里用 5 个真实运维任务对 2b/4b 做实测,用数据决定默认档。

### 交付

- `fetch-bundle.sh` 联网备齐全部产物 + `MANIFEST.sha256`;`install.sh` 端到端:sha256 校验 → 逐项检测安装 → 自动配置 → 起服务 → 冒烟(chat+tools、pi 端到端)
- 全部装在 `~/pi-ops-agent`(不动系统目录、不需要 root);systemd `--user` 优先,不可用时 nohup 兜底
- 产物来源全部走国内可达通道:npmmirror(node/npm)、github release(llama.cpp,断点重试×3)、hf-mirror(模型 GGUF)
- ⚠️ 模型 GGUF 选 bartowski(llama.cpp 官方转换器产出):Ollama registry 的 qwen3.5 GGUF 与 llama.cpp 加载器存在 rope 段数约定错配(`expected 4, got 3`),不能用
- llama.cpp 预编译二进制 glibc 门槛随版本漂移:目标机发行版过老时,在老基础容器里自编译后替换 bundle 里的 tarball 即可

## 安全模型(pi 的特殊性)

pi 没有任何内置审批弹窗——bash 以运行用户权限直接执行。本仓库用扩展补多层防线:

- **危险命令审批门**(`assets/extensions/ops-tools.ts`):语义化判定(经对抗评审多轮绕过测试)——rm 的分离/合并/长旗标 r+f 共现、关机组(含 poweroff)、块设备覆写(dd of=/tee/cp→/dev//shred/blkdiscard/mkfs/find -delete)、写 /etc 与 ~/.ssh/systemd 单元、下载即执行(curl|sh 全变形含 `| sudo bash`、`bash <(curl)`、两步落地)、systemctl 只放行读动词、pkill/killall 关键进程、防火墙写操作、chmod 放开;headless(`-p`)无法交互时**默认拒绝**。安装冒烟内置一道实测(创建临时目录→让模型 `rm -rf`→断言目录未被删)
- **写类工具门**:write/edit 写敏感路径(~/.ssh、systemd 用户单元、/etc、shell 配置)同样要求确认,堵"绕过 bash 直写持久化入口"的结构性绕过
- **llama-server 加 api-key**:虽仅绑 127.0.0.1,防止本机其他进程免鉴权调用/灌上下文;key 装在 `~/pi-ops-agent/llama.key`(600),pi 侧自动携带
- **systemd --user + linger**:服务常驻(SSH 登出不停止);不可用时 nohup 兜底并在横幅明示
- **bundle 完整性**:MANIFEST sha256 校验 + 清单外文件拒绝(防塞入字典序靠前的 node/额外 gguf);⚠️ 清单由联网机自算无签名——**只防搬运损坏,信任锚点是备货的联网机**,高安全场景需对产物做 GPG 签名
- 上述均为 best-effort 纵深防御,**不是沙箱**;生产建议叠加:专用低权限用户 / 容器运行

## 评测结果(2026-09-11,WSL,5 个真实运维任务)

任务:磁盘用量 / 服务状态 / 最大日志文件 / 内存 Top5 / 端口占用定位(最难,需多步:查端口→找进程→定性)。

| 模型 | 结果 | 观感 |
|---|---|---|
| qwen3.5-4b | **5/5** | 答案质量高:port8080 正确指出 docker-proxy + 容器 IP + 双栈监听;memtop 连 llama-server 自身占用(~5GB)都观察到了 |
| qwen3.5-2b | 5/5 → 4/5(两轮) | **不稳定**:简单题可过;port8080 第一轮答案含糊(只谈"8080 是 Node 常用端口"),第二轮直接 300s 超时零输出 |

结论:**默认 2b 是资源受限场景的取舍**(用户指定),多步任务有明显的质量与稳定性波动;**4b 是可靠档**——切换只需 `pi-ops --model llama-cpp/qwen3.5-4b`(换默认改 settings.json 或重装时指定)。跑分脚本:`tests/eval-ops.sh [模型id]`。

## Roadmap

- [x] WSL PoC:fetch-bundle + install 全流程跑通,pi 对接本地 llama-server(2026-09-11)
- [x] 最小运维骨架验证:SYSTEM.md + 只读工具(返回真实数据)+ 审批门实测拦截 rm -rf(2026-09-11)
- [x] 5 个真实运维任务对 qwen3.5-2b / 4b 实测:4b 稳 5/5;2b 有波动(见「评测结果」)(2026-09-11)
- [ ] 真机内网交付演练(tarball 拷贝 → install → 冒烟)
- [ ] 对抗评审后续:上游产物钉版 + 哈希固定(MANIFEST 目前只防搬运损坏)
- [ ] 可选:`scripts/build-binaries.sh --offline-model-data` 单二进制形态对比

## 参考

- [pi 官网与文档](https://pi.dev) / [earendil-works/pi 仓库](https://github.com/earendil-works/pi)
- [llama.cpp function-calling 文档](https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md)
- [Ollama registry](https://registry.ollama.ai)(模型 blob 来源,协议即 docker registry v2)
- [Docker: 本地 LLM 工具调用实测](https://www.docker.com/blog/local-llm-tool-calling-a-practical-evaluation/)
- [Qwen3 技术报告](https://arxiv.org/html/2505.09388v1) / [Qwen3-30B-A3B-Instruct-2507 模型卡](https://huggingface.co/Qwen/Qwen3-30B-A3B-Instruct-2507)

## License

[MIT](./LICENSE)
