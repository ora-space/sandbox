# 两轮需求逐项回应

本文把两份输入要求映射到本仓库实现：

- 第一轮：`sandbox对接.md`，更新日期 2026-09-16，定义云端平台能力、责任边界和待确认项。
- 第二轮：`HANDOFF.md`，定义 Ora Cloud Controller 当前依赖的最小 Substrate Effects API、WebSocket 路由和恢复语义。

状态含义：

- **已实现并验证**：代码存在，且已在当前 Agent Substrate/gVisor POC 上验证。
- **已实现**：代码存在并有单元测试，但该项没有独立的生产验证。
- **部分实现**：POC 主路径存在，生产能力或完整 Ora 业务流程仍缺失。
- **外部职责**：由 Ora Controller、Cloud 或基础设施完成，本仓库只提供边界。
- **待生产化**：POC 明确不承诺，生产上线前必须补齐。

## 第一轮需求回应

| 第一轮要求 | 回应 | 状态与证据 |
| --- | --- | --- |
| 按指定镜像创建沙盒并运行 Ora Node | `sandbox_ensure` 使用指定 ActorTemplate 创建 Actor；runtime 镜像启动 Ora Node v1 和 readiness | **已实现并验证**；`service/effects.go`、`runtime/Containerfile`、`deploy/ora-actor-template.json` |
| Controller 按沙盒 ID 建立双向长连接 | router 使用 `Ate-Target-Actor: <atespace>/<sandboxInstanceId>` 选择 Actor，并双向转发 WebSocket | **已实现并验证**；`service/router.go` |
| 连接前确认 Node 就绪并完成握手 | ensure 等待 `/readyz`；router 在接受下游 Upgrade 前先连上游；Node 要求首帧为 v1 `hello` | **已实现并验证**；握手后的业务就绪由 Controller 判断 |
| 状态查询和可重试销毁 | `GET /effects/{id}` 查询；同 ID 同请求 PUT 可重试；terminate 使用 tombstone 防止迟到创建 | **已实现并验证**；`docs/effects-api.md` |
| Node 访问 Git、Agent 服务和对象存储 | runtime 镜像包含 Git、SSH 和 CA；具体 egress、凭据和对象存储由部署平台配置 | **部分实现 / 外部职责**；见 `docs/configuration.md` 网络章节 |
| 执行、审批、保存期间保持运行 | 本服务不会因浏览器或 Controller 连接断开自动销毁 Actor，也不提供自动 suspend | **部分实现**；审批、Agent 执行、成果保存状态由 Ora Node/Controller 实现 |
| 交互式 Workspace 持久化 | `/workspace` 使用 `durableDir`，terminate 生成 DATA Tag，下一代从 Tag 恢复 | **已实现并验证** |
| 自动化 Workspace 保存后释放 | 提供 terminate；何时确认成果已保存并调用 terminate 由 Controller 决定 | **外部职责** |
| 浏览器断开不影响任务 | 浏览器不直连沙盒服务，服务没有按浏览器会话销毁 Actor 的逻辑 | **已实现边界**；任务本身是否继续取决于 Ora Node 的执行器 |
| Controller–Node 断线不重复派发 | Node 保存 execution ledger，支持 `get_execution_status`、未确认结果重放和 `event_ack` | **部分实现**；当前 runtime 只实现 worktree 操作，不是完整 Agent 任务协议 |
| 用户取消先停止并保存成果 | 不属于 Substrate 生命周期接口；应由 Controller–Node 协议完成后再 terminate | **外部职责 / 未实现完整业务流程** |
| bundle 上传失败时保留沙盒重试 | 服务不会自动 terminate；保留期限和重试由 Cloud/Controller 决定 | **外部职责** |
| 一个 Workspace 同时最多一个沙盒 | journal 拒绝第二个未终止 ensure；失败 effect 可在旧实例终止后重试 | **已实现并验证** |
| 长连接超时、保活和配额 | 当前转发保留 ping/pong、背压和 close；未实现主动 ping、空闲/总时长和连接数限制 | **待生产化** |
| 入口认证和授权 | POC 默认 loopback；controller ID 是协议绑定，不是完整服务认证 | **待生产化** |
| 实际部署版本与 Actor 映射 | `sandboxInstanceId=ensure effectId=Actor name`，atespace 来自配置 | **已确定**；Substrate 版本仍应由部署清单锁定 |
| 沙盒替换后的数据保留 | DATA snapshot 恢复 `/workspace`；Node ID 稳定、incarnation 改变 | **已实现并验证** |

## 第二轮需求回应

| 第二轮契约 | 回应 | 状态与证据 |
| --- | --- | --- |
| `effectId` 为 UUID 和幂等键 | 路径校验 UUID；journal 保存完整规范化请求 | **已实现** |
| intent 先于外部动作持久化 | 首次 PUT 先写 `running`，再调用 Substrate | **已实现**；`service/journal.go`、`service/effects.go` |
| 同 ID 同请求重试，不同请求 409 | succeeded 固定返回；failed 可重试；payload 改变返回 `effect_conflict` | **已实现并验证** |
| GET 不产生新沙盒动作 | GET 只读 journal，并只允许对既有 running 状态进行 Substrate 对账 | **已实现** |
| `sandbox_ensure` 返回 sandbox/node 身份 | 返回 `sandboxInstanceId=effectId` 和 `nodeId=workspace-<workspaceId>` | **已实现并验证** |
| ensure 不等于 Node 会话已握手 | ensure 只确认 runtime readiness；Controller 仍执行 Node hello/heartbeat | **已实现边界** |
| terminate 先 tombstone，防止迟到 ensure | tombstone 在 suspend/delete 前原子持久化，router 立即拒绝旧目标 | **已实现并验证** |
| Workspace 数据跨代保留 | suspend → DATA Tag → delete；下一代 Actor 使用 Tag 创建 | **已实现并验证** |
| `workspace_data_delete` 幂等 | 无活动 Actor时删除 pending/current Tag；数据不存在也成功 | **已实现并验证** |
| `running/succeeded/failed` 恢复 | journal 持久化状态；服务重启可查询历史并对账关键 running 操作 | **已实现 POC**；多副本事务恢复待生产化 |
| 404 与 503 路由语义区分 | 不存在/已终止返回 404；已知但非 succeeded/running 返回 503 | **已实现并验证** |
| 接受下游 Upgrade 前连接 Node | router 先 dial upstream，再 Upgrade Controller 连接 | **已实现** |
| binary message、16 MiB、close 传播 | 两段独立 WebSocket，保留类型/内容并设置 16 MiB read limit | **已实现** |
| Node v1 身份与代次 | 稳定 `node_id` 存在 `/workspace`；进程启动生成新 `incarnation_id` | **已实现并验证** |
| 不向生命周期服务传 Git 密钥 | Effects 请求只接受 kind/project/workspace/sandbox ID，拒绝未知字段 | **已实现** |
| 首版无 suspend/resume | API 拒绝 `sandbox_suspend`；内部 suspend 仅用于 terminate snapshot | **已实现并验证** |
| 插件 effects | 本适配器返回 `unsupported_kind`，插件 effect 需由 Cloud 另行实现 | **按第二轮边界处理** |
| 生产身份与 Project/Workspace 授权 | scope 冲突在 journal 内校验；调用者身份、TLS 和授权策略尚未实现 | **待生产化** |

## 两轮需求之间的收敛

第二轮没有取消第一轮的业务目标，而是把平台边界变得可实现和可恢复：

1. “创建、状态、销毁”统一为 Cloud 预分配 ID 的 Effects API。
2. “按沙盒 ID 长连接”明确为 `Ate-Target-Actor` 寻址的受控 WebSocket router。
3. “持久 Workspace”明确为 DATA snapshot，不恢复旧进程内存或旧连接。
4. suspend/resume 不暴露给 Controller，避免把基础设施暂停状态混入 Ora 业务状态。
5. Node 握手、Agent 任务、审批、clone、成果保存和重放仍属于 Controller–Node 协议；沙盒路由只传输消息。
6. 生产认证、授权、高可用 journal、连接配额和完整 Agent 协议保持为后续工作，不能从 POC 成功推断已完成。

## 验收使用方法

接口语义以 `docs/effects-api.md` 为准；部署参数以 `docs/configuration.md` 为准；真实 POC 证据以 `docs/verification.md` 为准。评审新需求时，应在本表中增加一行并标明责任方、实现文件、验证命令和生产差距，避免只更新代码而遗漏契约。
