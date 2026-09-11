# pi-intranet-ops-agent

内网(air-gapped)离线部署运维 Agent:基于开源 agent 框架 [pi](https://pi.dev) + 本地 Qwen 小模型,打包成**免联网、直接安装**的离线交付包,跑在无法访问互联网的内网/客户现场服务器上。

> 状态:构想与选型验证阶段(2026-09 调研结论落档)。尚无可运行代码。

## 总体架构

```
┌─ 内网服务器(无互联网)──────────────────────────┐
│ systemd → ollama serve / llama-server            │  模型服务层(OpenAI 兼容)
│             └─ GGUF 本地导入,零 registry 拉取    │
│ pi (Node ≥ 22) ──HTTP──→ localhost:11434         │  agent 层
│   ├─ ~/.pi/agent/models.json   指向本地模型端点   │
│   ├─ extensions/*.ts           运维工具 + 审批门  │
│   └─ SYSTEM.md                 运维角色系统提示词 │
└──────────────────────────────────────────────────┘
```

## 关键选型结论(2026-09 调研,均有出处)

### 框架:pi(`@earendil-works/pi-coding-agent`)

- MIT 许可,可打包进内部离线分发(保留版权声明即可)
- 本地模型一等公民:Ollama / llama.cpp / LM Studio / vLLM / 任意 OpenAI 兼容端点
- TS 扩展免编译(jiti 加载):可注册自定义运维工具、覆盖全部内置工具(bash/read/write…)、`SYSTEM.md` 整体替换系统提示词——"改造成运维 agent"是官方意图内的用法
- `PI_OFFLINE=1` 关闭全部启动期网络行为(版本检查/目录刷新/遥测),只剩模型端点一个网络依赖
- ⚠️ **安全模型与 Claude Code 相反:没有任何内置审批弹窗**,bash 以运行用户权限直接执行。生产必须:自写 `tool_call` 事件拦截扩展(~10 行)做人工确认 + 容器/受限用户隔离
- ⚠️ 旧 npm scope `@mariozechner/pi-coding-agent` 已废弃,钉新包名
- bun 是官方安装方式之一(pi.dev 安装区 5 tabs),但包操作路径仍默认调 npm(适配中:pi#6396),纯 bun 无 npm 环境扩展加载会崩(pi#4160)

### 模型:不要低于 4B

| 档位 | Ollama tag | 体积 | 内存 | 适用 |
|---|---|---|---|---|
| 绝对下限 | `qwen3.5:4b` | 3.4GB | ~8GB | 窄场景、固定工具集、人在环逐步确认 |
| 推荐 | `qwen3.5:9b` | 6.6GB | ~12GB | 多步运维循环的可靠起点 |
| CPU-only 最优 | Qwen3-30B-A3B-Instruct-2507 类 MoE | ~19GB | 16GB 勉强 / 24-32GB 舒适 | MoE 每 token 仅激活 3.3B,CPU 上 10-20+ tok/s;agentic 能力接近 GPT-4o |

核心依据:

- 2B 级多轮工具调用崩塌:0.6B 单轮 84% → 5 轮 42%(distil-labs);Docker 3570 用例实测工具选择 F1:3-4B 级 0.72-0.73 vs Qwen3-8B 0.919、14B 0.971(≈GPT-4 的 0.974)
- 中文多约束指令(Multi-IF):1.7B=44.7 vs 4B=61.3——"改 X 配置第 N 行但别动 Y"这类运维指令,小模型丢约 1/3 约束
- 纯 CPU 服务器优先 MoE:速度由激活参数决定,质量由总参数决定

### 交付:裸机 tarball 为主

- 组成:模型服务(ollama tarball 或 llama-server 单二进制)+ GGUF + pi(Node 运行时 + node_modules bundle,或官方 `scripts/build-binaries.sh --offline-model-data` 单二进制)+ 幂等 `install.sh` + systemd unit
- 校验:全产物 sha256;Ollama blob 文件名即摘要,可自校验
- 冒烟:`curl 127.0.0.1:11434/api/tags` + 带 tools 数组的 chat 请求 + `ss -tnp` 确认无预期外外联
- Docker save/load 为备选(仅目标机已有引擎时);vLLM 纯 CPU 不值得碰

## 已知坑(先记下,别踩)

- `OLLAMA_CONTEXT_LENGTH` 默认 **4096**:工具 schema 被截断 → 症状"模型死活不调工具",改 16k+
- Ollama **静默丢弃**不在工具列表里的幻觉工具名(无报错,排查极难)
- llama.cpp 预编译二进制 glibc 门槛随版本漂移(有 release 实际要 glibc 2.38):在最老的目标发行版先冒烟,或老基础容器自编译
- pi 启动会刷新模型目录缓存,离线回退 stale cache——预热缓存或 `PI_OFFLINE=1`

## Roadmap

- [ ] WSL 验证:ollama + `qwen3.5:4b` / `qwen3.5:9b`,pi 打通本地端点
- [ ] 最小运维骨架:SYSTEM.md + 3 个自定义工具(查日志/查磁盘/重启服务)+ `tool_call` 审批扩展
- [ ] 用 5 个真实运维任务测两个模型的多轮成功率,定 4b vs 9b
- [ ] 离线打包 POC:tarball + install.sh + systemd + 冒烟
- [ ] `build-binaries.sh --offline-model-data` 单二进制 POC

## 参考

- [pi 官网与文档](https://pi.dev) / [earendil-works/pi 仓库](https://github.com/earendil-works/pi)
- [Ollama Linux 离线安装](https://docs.ollama.com/linux) / [GGUF 离线导入](https://docs.ollama.com/import) / [qwen3.5 库页](https://ollama.com/library/qwen3.5)
- [llama.cpp function-calling 文档](https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md)
- [Docker: 本地 LLM 工具调用实测](https://www.docker.com/blog/local-llm-tool-calling-a-practical-evaluation/)
- [Qwen3 技术报告](https://arxiv.org/html/2505.09388v1) / [Qwen3-30B-A3B-Instruct-2507 模型卡](https://huggingface.co/Qwen/Qwen3-30B-A3B-Instruct-2507)

## License

[MIT](./LICENSE)
