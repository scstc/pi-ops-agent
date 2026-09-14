# pi-ops-agent

面向内网和客户现场的离线运维 Agent。它把 Node、pi、llama.cpp 和一个本地 Qwen GGUF 模型封装为无需 root、安装期间不访问网络的交付包；安装后可在目标服务器上用自然语言查询和分析运维问题。

当前发行版本为 **v26.3.11**。每个 Release 资产只包含一个模型和一个目标发行版，文件名会写明二者。离线包目前面向 x86_64 的麒麟 V10 / RHEL 8 系环境。

## 适用范围

| 项目 | 要求或实测边界 |
| --- | --- |
| CPU / 系统 | x86_64、glibc ≥ 2.28；已在麒麟 V10、Ubuntu 22.04/24.04 与 WSL Ubuntu 验证 |
| 基础命令 | `bash`、`tar`、`xz`、`curl`；`systemctl`、`ss`、`timeout` 缺失时会降级，不阻止安装 |
| 2B 档内存 | 至少 4.5 GB，8 GB 较舒适；实测 llama-server 常驻约 3.2 GB、空闲 CPU 接近 0 |
| 磁盘 | 安装目录至少 5 GB 可用空间；运行 `.run` 时临时目录还需容纳一份解压内容 |
| 0.8B 档 | 用于内存更紧的轻量问答和巡检；最低可用内存尚未完成实测，预检会告警后继续由安装冒烟验证 |

发布包有两档模型：

| 模型 | 使用建议 | 已知边界 |
| --- | --- | --- |
| `qwen3.5-0.8b` | 资源很紧、简单问答或轻量巡检 | 工具调用与复杂归因能力较弱 |
| `qwen3.5-2b` | 默认推荐，用于受限机器上的常规运维问答 | 多轮复杂任务的归因深度有限，可能出现小模型幻觉 |

`2B`、`0.8B` 是模型参数档位，不能当作交付包大小。2B 使用的 Q4_K_M GGUF 模型文件实测约 1.4 GB；Release 包还包含 Node、pi、llama.cpp 和脚本，实际下载大小以 Release 资产显示为准。

历史 WSL 纯 CPU 评测中，2B 在五个真实运维任务的两轮测试为 5/5，能定位 `docker-proxy` 和 PID，但归因较浅。仓库中的 `tests/eval-ops.sh [模型id]` 可复现评测；不要将该结果视为所有现场环境的性能承诺。

## Quick start：联网备货到离线首次问答

下面以 `kylin-v10` 的 2B 包为例。0.8B 只需把文件名中的 `qwen3.5-2b` 换成 `qwen3.5-0.8b`。

### 1. 在联网 Windows 机器下载并校验

需要已登录 GitHub CLI 的 PowerShell。下载 `.run` 和同名校验文件，然后比较 SHA-256：

```powershell
gh release download v26.3.11 -R scstc/pi-ops-agent `
  -p "pi-ops-agent-v26.3.11-kylin-v10-qwen3.5-2b-x64.run" `
  -p "pi-ops-agent-v26.3.11-kylin-v10-qwen3.5-2b-x64.run.sha256"

$file = "pi-ops-agent-v26.3.11-kylin-v10-qwen3.5-2b-x64.run"
$expected = (Get-Content "$file.sha256").Split()[0].ToLower()
$actual = (Get-FileHash $file -Algorithm SHA256).Hash.ToLower()
if ($actual -ne $expected) { throw "SHA-256 校验失败：请重新下载 $file" }
```

也可在联网 Linux 机器使用：

```bash
gh release download v26.3.11 -R scstc/pi-ops-agent \
  -p 'pi-ops-agent-v26.3.11-kylin-v10-qwen3.5-2b-x64.run' \
  -p 'pi-ops-agent-v26.3.11-kylin-v10-qwen3.5-2b-x64.run.sha256'
sha256sum -c pi-ops-agent-v26.3.11-kylin-v10-qwen3.5-2b-x64.run.sha256
```

把 `.run` 和同名 `.sha256` 两个文件拷贝到现场服务器，例如通过 U 盘或受控的内网文件传输。无需在现场服务器安装 GitHub CLI、Node、npm、Ollama 或编译工具。

### 2. 在离线服务器安装

在存放安装包的目录中再次校验，确认传输没有损坏。`PI_OPS_HOME` 指定安装目录，默认是 `~/pi-ops-agent`；需要使用其他磁盘时先设置它。`TMPDIR` 可指定自解压位置。

```bash
export PI_OPS_HOME="${PI_OPS_HOME:-$HOME/pi-ops-agent}"
sha256sum -c pi-ops-agent-v26.3.11-kylin-v10-qwen3.5-2b-x64.run.sha256
bash ./pi-ops-agent-v26.3.11-kylin-v10-qwen3.5-2b-x64.run
```

`.run` 会先校验内置载荷，再解压、运行 `env-check.sh` 和 `install.sh`，最后删除临时目录。安装器还会校验 `bundle/MANIFEST.sha256`、启动本地模型服务，并执行 chat、pi 端到端和危险删除拦截的冒烟测试。整个安装过程不下载依赖。

首次安装后，当前 shell 的 PATH 不会自动刷新。请先使用绝对路径完成第一次问答：

```bash
"$PI_OPS_HOME/bin/pi-ops" -p "查看当前磁盘使用情况，并给出清理建议。"
```

之后新开终端即可使用 `pi-ops`。若使用 bash，也可执行 `source ~/.bashrc`；zsh 用户执行 `source ~/.zshrc`。安装器只会更新已经存在的对应 rc 文件，两个文件都不存在时才创建 `~/.bashrc`。

### 3. `.tar.gz` 备用安装方式

现场策略不允许执行自解压脚本时，下载匹配的 `.tar.gz` 和 `.tar.gz.sha256`，先校验再解压：

```bash
sha256sum -c pi-ops-agent-v26.3.11-kylin-v10-qwen3.5-2b-x64.tar.gz.sha256
mkdir -p pi-ops-package
tar -xzf pi-ops-agent-v26.3.11-kylin-v10-qwen3.5-2b-x64.tar.gz -C pi-ops-package
cd pi-ops-package
bash env-check.sh
export PI_OPS_HOME="${PI_OPS_HOME:-$HOME/pi-ops-agent}"
./install.sh
"$PI_OPS_HOME/bin/pi-ops" -p "你好，请介绍你的运维能力。"
```

预检退出码 `0` 表示满足要求，`2` 表示只有可选项告警，`1` 表示存在硬性不满足项。`.run` 对退出码 `2` 会继续安装，对 `1` 会停止。

## 日常使用

以下维护命令使用安装目录变量。新终端中先执行 `export PI_OPS_HOME="${PI_OPS_HOME:-$HOME/pi-ops-agent}"`；自定义安装目录时把默认值换成实际路径。

```bash
pi-ops                                      # 交互 TUI，/quit 退出
pi-ops -p "检查磁盘使用情况"                 # 单次问答
pi-ops-verify 部署架构.md                    # 输出 verify-report-时间戳.md
pi-ops-verify 部署架构.md my-report.md       # 指定报告文件
systemctl --user status pi-ops-llama         # systemd 用户服务状态
```

模型服务仅监听 `127.0.0.1`，使用本地 API key。默认空闲 5 分钟会回收模型内存：

```bash
echo 0 > "$PI_OPS_HOME/idle-min"            # pi 退出即停止模型
echo 5 > "$PI_OPS_HOME/idle-min"            # 默认值：空闲 5 分钟回收
```

有 systemd 用户服务时，模型服务由 `pi-ops-llama` 管理，安装器会尝试启用 linger，使 SSH 退出后服务保留。没有可用 systemd 时会走 `nohup` 兜底；下次运行 `pi-ops` 会按需拉起模型，也可手动启动：

```bash
"$PI_OPS_HOME/bin/llama-run" &
```

## 部署验证

`pi-ops-verify` 根据架构 Markdown 生成报告。若文档包含 `deploy-spec` YAML 代码块，会先用 `ss`、`pgrep`、`systemctl`、`curl`、文件系统和网络探测得到确定性实测结果，再让 Agent 只负责对照、汇总和给出修复建议；这比纯模型理解更可靠。

```bash
pi-ops-verify /path/to/部署架构.md
```

规范和示例见 [deploy-spec-example.md](examples/deploy-spec-example.md)，将服务、端口、目录、文件、版本和连通性替换为现场实际要求即可；安装器不会把示例复制到安装目录。没有 `deploy-spec` 块时也能使用自由理解模式，但小模型的可靠性较低；复杂文档建议补全规范块。`deploy-spec` 模式中确定性实测有不符项时返回 `1`；全部符合且 Agent 正常完成时为 `0`，文档或启动器不存在时为 `2`，其他错误可能返回 Agent 或超时命令的退出码。

## 16K 上下文配置与旧安装修复

当前安装器已将 pi 的 `contextWindow` 固定为 16384、`maxTokens` 为 4096，并启用会话压缩（预留 6144 token，保留最近 4096 token），与 `llama-run -c 16384` 对齐。

旧版本若报 `400 exceed_context_size_error`，退出 pi 后执行以下修复。优先用安装包自带 Node；只有安装时复用了合格的系统 Node 才回退到系统 `node`：

```bash
export PI_OPS_HOME="${PI_OPS_HOME:-$HOME/pi-ops-agent}"
NODE="$PI_OPS_HOME/node/bin/node"
[ -x "$NODE" ] || NODE="$(command -v node)"
"$NODE" <<'JS'
const fs = require('fs');
const path = require('path');
const dir = path.join(process.env.HOME, '.pi', 'agent');
function update(name, change) {
  const file = path.join(dir, name);
  const value = JSON.parse(fs.readFileSync(file, 'utf8'));
  fs.copyFileSync(file, `${file}.${Date.now()}.bak`);
  change(value);
  fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n');
}
update('models.json', value => {
  for (const model of value.providers['llama-cpp'].models) {
    model.contextWindow = 16384;
    model.maxTokens = 4096;
  }
});
update('settings.json', value => {
  value.compaction = {...value.compaction, enabled: true, reserveTokens: 6144, keepRecentTokens: 4096};
  value.branchSummary = {...value.branchSummary, reserveTokens: 4096};
});
JS
"$PI_OPS_HOME/bin/pi-ops"
```

单次输入或工具输出仍可能过大。使用 `/new` 开始新会话，或在尚未超限时用 `/compact` 压缩历史，并限制日志查询的行数。

如果工作目录存在 `.pi/settings.json`，检查其中是否覆盖了全局压缩设置。升级会备份已有配置，并重写 `models.json`、`SYSTEM.md`、默认模型和上下文压缩参数；已有定制先单独留存。

## 升级与卸载

升级时下载、校验并安装新的匹配离线包即可。安装器会按校验和替换损坏或更新过的模型，并以包内 `default-model.txt` 重新设置默认模型。

卸载应在已解压的发行包目录中运行：

```bash
./uninstall.sh       # 交互确认
./uninstall.sh -y    # 无交互，用于脚本
```

卸载会停止服务、删除 `$PI_OPS_HOME`、还原安装前备份的 pi 配置并清理 shell PATH 行；会保留 `~/.pi/agent/sessions` 会话历史和 linger 设置。

## 故障排查

| 现象 | 处理 |
| --- | --- |
| `pi-ops: command not found` | 首次安装后用 `"$PI_OPS_HOME/bin/pi-ops"`，或新开 shell / source 对应 rc 文件 |
| 预检失败 | 按 `env-check.sh` 的 `FAIL` 行处理：x86_64、glibc ≥ 2.28、基础命令、2B 的 4.5 GB 内存和 5 GB 磁盘是重点 |
| 模型 120 秒未就绪 | 查看 `$PI_OPS_HOME/logs/llama.out`；有 systemd 时查看 `journalctl --user -u pi-ops-llama`；同时确认端口和模型完整性 |
| SSH 退出后模型停止 | 检查 `systemctl --user status pi-ops-llama`；若 linger 启用失败，需要管理员执行安装器提示的 `loginctl enable-linger <用户>` |
| 重启机器后模型未启动 | 运行 `pi-ops` 会按需拉起；`nohup` 兜底模式不会在开机时自启，也可执行 `"$PI_OPS_HOME/bin/llama-run" &` |
| 安装包校验失败 | 重新从联网机下载、再次比对 Release 的 `.sha256`，再重新传输；不要跳过校验 |

## 开发与构建

面向交付的包由 GitHub Actions 构建。CI 固定 llama.cpp `b10901`、Node `22.20.0`、pi `0.85.1`，在 Rocky Linux 8 容器中编译并生成 `kylin-v10` 的 0.8B、2B 包；随后以普通用户、全新 HOME 在独立运行时容器做离线安装验收。打 `v*` tag 后，全部构建和验收通过才创建并公开 Release。

本地开发备货脚本用于联网 Linux x86_64 环境：

```bash
./fetch-bundle.sh          # 备 2B 默认模型和 4B 备选模型
./fetch-bundle.sh --skip-4b
```

它将素材写入 `bundle/` 并生成 `MANIFEST.sha256`；之后把整个目录带入内网运行 `./install.sh`。本地备货脚本会解析上游可用版本，和 CI 的固定交付构建不是同一条版本控制路径；正式现场交付请使用 Release 包。

## 安全边界

安装包提供危险命令审批门、敏感路径写入门和仅绑定回环地址的模型 API key。headless 模式中无法交互确认的危险命令默认拒绝；安装冒烟会验证诱导的 `rm -rf` 没有执行。

这不是沙箱。pi 中的工具仍以当前用户权限执行，生产环境应使用专用低权限用户，并按现场要求叠加容器或系统隔离。`MANIFEST.sha256` 主要用于发现下载或传输损坏，信任锚点仍是联网备货机；高安全场景需要另行建立签名与上游哈希校验链。

## 参考

- [pi 文档](https://pi.dev)
- [earendil-works/pi](https://github.com/earendil-works/pi)
- [llama.cpp function calling](https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md)
- [bartowski Qwen3.5 GGUF](https://huggingface.co/bartowski/Qwen_Qwen3.5-2B-GGUF)

## License

[MIT](./LICENSE)
