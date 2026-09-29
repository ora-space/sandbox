# 详细配置

本文说明生命周期服务、WebSocket 路由、ActorTemplate、Ora Node 和 Ora Controller 的配置关系。示例值对应当前 `single-cluster` POC；复制到其他环境时必须替换 atespace、镜像、snapshot storage、kubeconfig 和入口地址。

## 端口和调用方向

| 端口 | 监听方 | 调用方 | 用途 | 默认暴露 |
| --- | --- | --- | --- | --- |
| `18002` | `ora-sandbox-service` | Ora Controller | Effects HTTP API | `127.0.0.1` |
| `18001` | `ora-sandbox-service` | Ora Controller | 受控 Ora Node WebSocket router | `127.0.0.1` |
| `18000` | Agent Substrate atenet ingress | sandbox router | Actor 内部入口 | `127.0.0.1` |
| `80` | Actor 内 runtime | atenet ingress | `/readyz`、`/process`、`/ora-node/v1` | 只经 Substrate 路由 |

Controller 不应直接访问 `18000` 或 Actor 的 `80`。生产环境在 `18001/18002` 前放置同一受控入口，终止 TLS，完成服务身份认证和 Project/Workspace 授权。

## 生命周期服务启动参数

`bin/ora-sandbox-service` 接受以下参数：

| 参数 | 示例默认值 | 说明 |
| --- | --- | --- |
| `-atespace` | `ate-coding-poc` | Actor、Tag 和寻址头所属 Atespace |
| `-template` | `ora-coding-v3` | 新建 Actor 使用的不可变 ActorTemplate |
| `-controller-id` | `ora-cloud-controller` | router 注入给 Node、并与 `hello.controller_id` 比对的身份 |
| `-kubectl-ate` | `/opt/substrate-poc/bin/kubectl-ate` | POC 调用 Substrate 的 CLI |
| `-kubeconfig` | `/opt/substrate-poc/config/kubeconfig` | `kubectl-ate` 使用的 kubeconfig |
| `-context` | `kind-substrate-poc` | kubeconfig context |
| `-internal-router` | `ws://127.0.0.1:18000` | atenet WebSocket ingress 基地址 |
| `-lifecycle-addr` | `127.0.0.1:18002` | Effects API 监听地址 |
| `-router-addr` | `127.0.0.1:18001` | Controller WebSocket router 监听地址 |
| `-state` | `/opt/substrate-poc/ora-sandbox-service/state/journal.json` | 单机原子 journal |

示例：

~~~bash
/opt/substrate-poc/bin/ora-sandbox-service \
  -atespace ate-coding-poc \
  -template ora-coding-v3 \
  -controller-id ora-cloud-controller \
  -kubectl-ate /opt/substrate-poc/bin/kubectl-ate \
  -kubeconfig /opt/substrate-poc/config/kubeconfig \
  -context kind-substrate-poc \
  -internal-router ws://127.0.0.1:18000 \
  -lifecycle-addr 127.0.0.1:18002 \
  -router-addr 127.0.0.1:18001 \
  -state /opt/substrate-poc/ora-sandbox-service/state/journal.json
~~~

journal 目录必须预先存在并只能由服务账号写入：

~~~bash
install -d -m 0700 /opt/substrate-poc/ora-sandbox-service/state
~~~

当前 journal 是单机 JSON 文件，写入采用 tempfile、文件 `fsync`、原子 rename 和目录 `fsync`。不要把它放在不支持原子 rename 的共享文件系统。多副本生产部署必须改为事务数据库，并按 Workspace 加分布式锁和 fencing。

## Ora Controller 配置

Controller 侧需要四个一致值：

~~~yaml
effects_url: http://127.0.0.1:18002
router_url: ws://127.0.0.1:18001/ora-node/v1
atespace: ate-coding-poc
controller_id: ora-cloud-controller
~~~

连接 router 时必须发送：

~~~http
Ate-Target-Actor: ate-coding-poc/<sandboxInstanceId>
~~~

其中 `sandboxInstanceId` 来自 `sandbox_ensure` 结果，等于该 ensure 的 `effectId`。Controller 的第一条 binary WebSocket 消息必须是协议 v1 `hello`，其中 `controller_id` 与服务的 `-controller-id` 一致。

如果 Controller 和服务不在同一主机，应在受控入口暴露 `18001/18002`，并把 URL 改成 `https://` 与 `wss://`。不要把内部 `18000` 暴露给 Controller。

## ActorTemplate

`deploy/ora-actor-template.json` 中需要按环境修改：

| JSON 路径 | 说明 |
| --- | --- |
| `metadata.atespace` | 必须与服务 `-atespace` 相同 |
| `metadata.name` | 必须与服务 `-template` 相同 |
| `workerSelector.matchLabels` | 选择已安装 gVisor 和镜像访问能力的 Worker |
| `containers[0].image` | Worker 可拉取的 Ora runtime 镜像；生产使用不可变 digest |
| `snapshotsConfig.storageLocation` | DATA snapshot 对象存储位置 |
| `sandboxConfig` | gVisor sandbox class 与部署中的 config name |
| `resources.limits` | 单 Actor CPU、内存上限 |

样例限制为 `1` CPU 和 `768Mi` 内存。`/workspace` 必须使用 `durableDir`，且 `onPause`、`onCommit` 保持 `SNAPSHOT_CONTENT_SCOPE_DATA`。这样恢复的是 Workspace 文件和 Node 持久账本，不恢复旧进程内存或旧 WebSocket。

ActorTemplate 不可更新；修改镜像或资源后应删除旧模板并以新名称或相同名称重建。正在运行的 Actor 不会自动切换镜像。

## Runtime 与 Ora Node

runtime 在 Actor 内监听 `:80`：

| 路径 | 方法 | 说明 |
| --- | --- | --- |
| `/readyz` | GET | Actor readiness |
| `/process` | POST | POC argv 执行入口；默认 30 秒，最大 120 秒 |
| `/ora-node/v1` | GET Upgrade | Ora Node v1 binary WebSocket |

router 建立上游连接时注入：

- `X-Ora-Node-Id: workspace-<workspaceId>`
- `X-Ora-Sandbox-Instance: <sandboxInstanceId>`
- `X-Ora-Controller-Id: <controller-id>`
- `Ate-Target-Actor: <atespace>/<sandboxInstanceId>`

Node 持久状态位于 `/workspace/.ora-node/state.json`。同一 Workspace 的 `node_id` 跨 Actor 代次稳定；`incarnation_id` 每次 Node 进程启动重新生成。仓库和 worktree 根目录分别是 `/workspace/repositories` 与 `/workspace/worktrees`。

runtime 支持可选环境变量 `ORA_CONTROLLER_ID` 和 `ORA_NODE_TOKEN`。通过本仓库 router 时，Controller 身份由注入的 `X-Ora-Controller-Id` 约束。当前 POC router 未配置 Node bearer token 注入，因此不要只在 runtime 设置 `ORA_NODE_TOKEN`；生产实现应从 secret file 读取 token并只在 router 到 Node 的内部链路注入，不能把 token写入模板、日志或 journal。

## 网络与代理

Actor 至少需要按业务允许访问用户 Git 远端、Agent 模型或工具服务、snapshot/object storage、DNS 和证书服务。平台应使用 egress allowlist。

若部署必须使用代理，在 ActorTemplate 中按平台支持方式注入 `HTTP_PROXY`、`HTTPS_PROXY` 和 `NO_PROXY`；`NO_PROXY` 至少覆盖 loopback、集群服务域、atenet ingress 和内部对象存储地址。服务调用本机 atenet 与 kube-api 时不应走外部代理。

## 安全配置

POC 的 loopback 监听不能代替生产鉴权。生产上线前至少完成：

1. `18001/18002` 使用 TLS，Controller 使用工作负载身份或 mTLS。
2. 入口校验调用者是否有权访问对应 Project、Workspace 和 effect。
3. Node 入口只允许受控 router；隔离内部 atenet。
4. kubeconfig、registry credential、Git credential 和 Node token 使用 secret file 或工作负载身份。
5. journal 与日志中不记录 credential、请求 Authorization 或 kubeconfig 内容。
6. 限制每个 Workspace 的连接数、空闲时间、总时长，并增加主动 ping。
7. 将 `kubectl-ate` 子进程替换为 ate-api gRPC client，并为多副本增加事务存储和 fencing。

## 配置一致性检查

~~~bash
systemctl cat ora-sandbox-service
systemctl status ora-sandbox-service
ss -lntp | grep -E '18000|18001|18002'

kubectl-ate --kubeconfig /opt/substrate-poc/config/kubeconfig \
  --context kind-substrate-poc get actor-template ora-coding-v3 \
  -a ate-coding-poc -o json
~~~

重点确认 service、Controller、ActorTemplate 中的 atespace、template name、controller ID 和端口完全一致。
