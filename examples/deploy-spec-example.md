# 示例:部署架构文档(部署验证用)

> 把你的部署架构 wiki 粘成这个格式即可。两种写法:
> - **推荐**:文档里放一个 ` ```deploy-spec ` YAML 块(agent 会严格逐条验证清单);
> - 兜底:不放 spec 块,agent 通读全文自由理解后验证(对随手贴的 wiki 可用,可靠性略低)。
>
> 用法:`pi-ops-verify examples/deploy-spec-example.md`

## XX 项目部署架构(2026-09)

本机承载指标中台与本地大模型服务,组件与端口如下。

```deploy-spec
services:
  - name: pi-ops llama-server        # 本地大模型推理(必须)
    port: 8787                       # 监听 127.0.0.1:8787
    process: llama-server
  - name: nacos                      # 注册中心
    port: 8848
  - name: k3d gateway                # k3d 集群网关
    port: 80
  - name: redis                      # 缓存(开发机上真实存在;若你的目标机未部署,实测层会如实标 ❌)
    port: 6379
dirs:
  - /home/change/pi-ops-agent/models # 模型目录必须存在
  - /opt/data/app                    # 应用数据目录(示例故意写不存在的路径)
files:
  - /etc/os-release
versions:
  - name: node(pi-ops 自带)
    command: ~/pi-ops-agent/node/bin/node -v
    expect: "v22"
connectivity: []                     # 跨机依赖(示例机无,格式: - host: 10.x.x.x  port: 3306)
```

## 部署说明(自由文本,agent 会结合理解)

- llama-server 由 systemd 用户服务 `pi-ops-llama` 管理,重启策略 on-failure;
- 所有服务只监听本机回环或内网网段;
- `dirs` 中列出的目录为运行时必需,缺失即视为部署不完整。
