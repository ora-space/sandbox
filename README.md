# ORA Agent Substrate Sandbox

本仓库是 ORA Cloud 与 [Agent Substrate](https://github.com/agent-substrate/substrate) 之间的独立沙盒适配层。它把 Cloud 已持久化的生命周期 effect 转换为 Actor、DATA Tag 和 Workspace 操作，并通过受控 WebSocket 路由连接沙盒内的 Ora Node v1。

当前版本面向单集群 POC、联调和镜像打包。生产环境还需要入口身份认证、TLS、Project/Workspace 授权、事务型 journal、多副本 fencing 和连接配额。

## 组件

| 目录 | 内容 |
| --- | --- |
| `service/` | `sandbox_ensure`、`sandbox_terminate`、`workspace_data_delete` Effects API 与 WebSocket 路由 |
| `runtime/` | 运行在 gVisor Actor 内的 Ora Node v1、命令执行入口和镜像 Containerfile |
| `deploy/` | ActorTemplate 与 systemd 示例 |
| `examples/controller-demo/` | 最小 Ora Node 二进制 WebSocket 协议客户端 |
| `docs/configuration.md` | 所有端口、启动参数、Controller、ActorTemplate 和安全配置 |
| `docs/requirements-response.md` | 第一轮与第二轮需求的逐项回应和当前完成度 |
| `docs/effects-api.md` | 生命周期接口、幂等、恢复和路由状态码 |
| `docs/deployment.md` | 构建、推送镜像、部署、演示、日志和打包 |
| `docs/verification.md` | 已完成的真实 Actor、gVisor 和 DATA snapshot 验证 |

## 架构

~~~text
Ora Cloud
   │ 计划并持久化 effect
   ▼
Ora Controller
   ├─ HTTP ───────▶ sandbox-service :18002 ──▶ kubectl-ate / ate-api
   └─ WebSocket ─▶ sandbox-router  :18001 ──▶ atenet :18000
                                                  │
                                                  ▼
                                      gVisor Actor / Ora Node :80
                                                  │
                                                  ▼
                                      durableDir /workspace + DATA Tag
~~~

`effectId` 同时是幂等键和 `sandboxInstanceId`。同一 Workspace 最多存在一个未终止 Actor。终止时先持久化 tombstone，再 suspend、生成 DATA Tag、删除 Actor；下一代 Actor 从 Tag 恢复 `/workspace`。

## 快速验证

需要 Go 1.27.1；构建镜像还需要 Docker 或兼容 OCI 构建器。

~~~bash
make test
make build
make image IMAGE=ora-sandbox-runtime:dev
~~~

生成的二进制位于 `bin/`。镜像只包含运行时；生命周期服务部署在 Substrate 控制侧。

部署前至少修改：

1. `deploy/ora-actor-template.json` 的镜像地址和 snapshot storage。
2. systemd 参数中的 atespace、ActorTemplate、kubeconfig 和 context。
3. Ora Controller 的 `effects_url`、`router_url`、`atespace` 与 `controller_id`。
4. 生产入口的 TLS、身份认证和授权策略。

完整步骤见 [部署说明](docs/deployment.md)，完整参数见 [配置说明](docs/configuration.md)。

## 部署

下面给出单机控制侧加 Agent Substrate 集群的最短部署路径。生产部署前先阅读 [详细配置](docs/configuration.md) 和 [生产差距](docs/deployment.md#10-生产差距)。

### 1. 获取代码并验证

~~~bash
git clone https://github.com/ora-space/sandbox.git
cd sandbox

make test
make test-race
make vet
make build
~~~

Go 依赖已提交在 `vendor/`，因此 Go 编译阶段可以不访问模块代理。生成的二进制位于 `bin/`。

### 2. 构建并推送 runtime 镜像

~~~bash
IMAGE=registry.example.com/ora/sandbox-runtime:2026.09.29

make image IMAGE="$IMAGE"
docker push "$IMAGE"
docker inspect --format='{{index .RepoDigests 0}}' "$IMAGE"
~~~

将输出的不可变 digest 写入 `deploy/ora-actor-template.json` 的 `containers[0].image`。同时按目标集群修改：

- `metadata.atespace` 和 `metadata.name`；
- `workerSelector.matchLabels`；
- `snapshotsConfig.storageLocation`；
- `sandboxConfig.configName`；
- CPU 和内存 limits。

创建 ActorTemplate：

~~~bash
kubectl-ate \
  --kubeconfig /opt/substrate-poc/config/kubeconfig \
  --context kind-substrate-poc \
  create actor-template -f deploy/ora-actor-template.json
~~~

ActorTemplate 不可更新。镜像、资源或 snapshot 配置变化时，应创建新版本模板，并将生命周期服务切换到新模板名。

### 3. 安装生命周期服务和 WebSocket router

先编辑 `deploy/ora-sandbox-service.service`，确认以下参数与实际环境一致：

- `-atespace`、`-template`、`-controller-id`；
- `-kubectl-ate`、`-kubeconfig`、`-context`；
- `-internal-router`；
- `-lifecycle-addr`、`-router-addr` 和 `-state`。

未显式写入 unit 的参数使用 [配置说明](docs/configuration.md#生命周期服务启动参数) 中的默认值。

~~~bash
sudo install -d -m 0755 /opt/substrate-poc/bin
sudo install -m 0755 bin/ora-sandbox-service /opt/substrate-poc/bin/
sudo install -m 0755 bin/ora-controller-demo /opt/substrate-poc/bin/
sudo install -d -m 0700 /opt/substrate-poc/ora-sandbox-service/state
sudo install -m 0644 deploy/ora-sandbox-service.service /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable --now ora-sandbox-service
~~~

### 4. 配置 Ora Controller

~~~yaml
effects_url: http://127.0.0.1:18002
router_url: ws://127.0.0.1:18001/ora-node/v1
atespace: ate-coding-poc
controller_id: ora-cloud-controller
~~~

四个值必须与 systemd unit 和 ActorTemplate 一致。跨主机时，通过带身份认证和 TLS 的入口提供 `https://` 与 `wss://` 地址。只向 Controller 暴露 `18001/18002`；`18000` 是内部 atenet ingress。

### 5. 部署后检查

~~~bash
systemctl status ora-sandbox-service
journalctl -u ora-sandbox-service -n 100 --no-pager
ss -lntp | grep -E '18000|18001|18002'

# 使用合法但不存在的 effect ID，预期返回 404 not_found
curl -i http://127.0.0.1:18002/effects/00000000-0000-4000-8000-000000000001

# 未进行 WebSocket Upgrade，预期返回 426
curl -i http://127.0.0.1:18001/ora-node/v1
~~~

创建 Actor、Node 握手、terminate、DATA Tag 恢复和数据删除的完整演示见 [部署与镜像打包](docs/deployment.md#7-最小生命周期演示)。Substrate Actor 与 Tag 的检查命令见同文档的[运行状态与日志](docs/deployment.md#8-运行状态与日志)。

## 外部接口

~~~text
GET /effects/{effectId}
PUT /effects/{effectId}
GET /ora-node/v1       WebSocket Upgrade
~~~

首版只接受 `sandbox_ensure`、`sandbox_terminate` 和 `workspace_data_delete`。首版不向 Controller 提供 suspend/resume。Substrate suspend 只在 terminate 内部用于生成一致的 DATA snapshot。Ora 应用帧保持 binary WebSocket message，路由不解析业务 payload，单条消息最大 16 MiB。

## 默认资源

示例 ActorTemplate 为每个沙盒设置：

- CPU：`1`
- 内存：`768Mi`
- 隔离：`SANDBOX_CLASS_GVISOR`
- 持久目录：`/workspace`
- 快照范围：`SNAPSHOT_CONTENT_SCOPE_DATA`

这些是部署样例值，需要按 Agent、仓库规模和并发测试结果调整。

## 文档入口

- [详细配置](docs/configuration.md)
- [两轮需求回应](docs/requirements-response.md)
- [Effects 与路由契约](docs/effects-api.md)
- [部署与镜像打包](docs/deployment.md)
- [验证证据](docs/verification.md)

## 安全边界

POC 默认监听 `127.0.0.1`，这只是网络边界。生产环境必须验证调用者身份及 Project、Workspace、effect 作用域；Node 入口只能由受控 router 访问；日志和 journal 不得保存 Git 密钥、访问令牌或 kubeconfig 内容。
