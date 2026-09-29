# 构建、部署与镜像打包

## 1. 前提

- Go 1.27.1
- Docker、Podman 或兼容 OCI 构建器
- 可用的 Agent Substrate、Atespace、WorkerPool 和 `kubectl-ate`
- gVisor sandbox class
- Worker 可访问的 OCI registry
- Actor 可访问的 snapshot storage
- 受控的 atenet ingress

## 2. 本地验证

~~~bash
make test
make test-race
make vet
make build
~~~

对应的直接命令：

~~~bash
go test ./...
go test -race ./...
go vet ./...
go build ./service ./runtime ./examples/controller-demo
~~~

## 3. 构建和导出镜像

从仓库根目录执行：

~~~bash
make image IMAGE=ora-sandbox-runtime:dev
docker inspect ora-sandbox-runtime:dev
~~~

离线传输：

~~~bash
docker save ora-sandbox-runtime:dev | gzip > ora-sandbox-runtime-dev.tar.gz
sha256sum ora-sandbox-runtime-dev.tar.gz

# 目标 Worker 或 registry 主机
gzip -dc ora-sandbox-runtime-dev.tar.gz | docker load
~~~

推送 registry：

~~~bash
docker tag ora-sandbox-runtime:dev registry.example.com/ora/sandbox-runtime:2026.09.28
docker push registry.example.com/ora/sandbox-runtime:2026.09.28
docker inspect --format='{{index .RepoDigests 0}}' registry.example.com/ora/sandbox-runtime:2026.09.28
~~~

把得到的不可变 digest 写入 `deploy/ora-actor-template.json`。生产环境不要只用可变 tag。

## 4. 创建 ActorTemplate

先修改：

- `metadata.atespace`
- `metadata.name`
- `workerSelector`
- `containers[0].image`
- `snapshotsConfig.storageLocation`
- `sandboxConfig.configName`
- CPU 和内存 limits

创建模板：

~~~bash
kubectl-ate \
  --kubeconfig /opt/substrate-poc/config/kubeconfig \
  --context kind-substrate-poc \
  create actor-template -f deploy/ora-actor-template.json
~~~

ActorTemplate 不可更新。变更配置时先确认没有新 Actor继续使用旧模板，然后删除并重建，或创建新版本名称并切换服务的 `-template`。

## 5. 安装生命周期服务

~~~bash
make build

install -d -m 0755 /opt/substrate-poc/bin
install -m 0755 bin/ora-sandbox-service /opt/substrate-poc/bin/
install -m 0755 bin/ora-controller-demo /opt/substrate-poc/bin/
install -d -m 0700 /opt/substrate-poc/ora-sandbox-service/state
install -m 0644 deploy/ora-sandbox-service.service /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now ora-sandbox-service
~~~

启动前编辑 unit 中的 atespace、template、kubeconfig、context 和端口。完整参数见 [configuration.md](configuration.md)。

## 6. 配置 Ora Controller

~~~yaml
effects_url: http://127.0.0.1:18002
router_url: ws://127.0.0.1:18001/ora-node/v1
atespace: ate-coding-poc
controller_id: ora-cloud-controller
~~~

跨主机部署应通过认证的 `https://` 和 `wss://` 入口访问。只暴露 `18001/18002`，不要暴露内部 atenet `18000`。

## 7. 最小生命周期演示

~~~bash
PROJECT_ID=11111111-1111-4111-8111-111111111111
WORKSPACE_ID=22222222-2222-4222-8222-222222222222
ENSURE_ID=33333333-3333-4333-8333-333333333333

curl --noproxy '*' -X PUT \
  -H 'Content-Type: application/json' \
  --data "{\"kind\":\"sandbox_ensure\",\"projectId\":\"$PROJECT_ID\",\"workspaceId\":\"$WORKSPACE_ID\"}" \
  "http://127.0.0.1:18002/effects/$ENSURE_ID"

bin/ora-controller-demo "$ENSURE_ID" status
~~~

终止使用新的 effect ID：

~~~bash
TERMINATE_ID=44444444-4444-4444-8444-444444444444
curl --noproxy '*' -X PUT \
  -H 'Content-Type: application/json' \
  --data "{\"kind\":\"sandbox_terminate\",\"projectId\":\"$PROJECT_ID\",\"workspaceId\":\"$WORKSPACE_ID\",\"sandboxInstanceId\":\"$ENSURE_ID\"}" \
  "http://127.0.0.1:18002/effects/$TERMINATE_ID"
~~~

创建新的 ensure effect 可验证 DATA Tag 恢复。确定不再需要 Workspace 数据后，使用第三个新 effect ID 调用 `workspace_data_delete`。

## 8. 运行状态与日志

~~~bash
systemctl status ora-sandbox-service
journalctl -u ora-sandbox-service -f
ss -lntp | grep -E '18000|18001|18002'

kubectl-ate --kubeconfig /opt/substrate-poc/config/kubeconfig \
  --context kind-substrate-poc get actor <sandbox-id> \
  -a ate-coding-poc -o json

kubectl-ate --kubeconfig /opt/substrate-poc/config/kubeconfig \
  --context kind-substrate-poc logs actor <sandbox-id> \
  -a ate-coding-poc

kubectl-ate --kubeconfig /opt/substrate-poc/config/kubeconfig \
  --context kind-substrate-poc get tag \
  -a ate-coding-poc -o json
~~~

审计时可以从 journal 查看 effect 的 request、state、result/error，以及 Workspace 的 active sandbox、current/pending Tag 和 tombstone。不要直接编辑 journal；修复前先停服务并保存副本。

## 9. 升级顺序

1. 构建并推送新 runtime digest。
2. 创建新版本 ActorTemplate。
3. 更新 service unit 的 `-template` 并重启服务。
4. 新 ensure 使用新模板；已有 Actor 继续使用旧版本。
5. 验证 terminate、DATA Tag 和下一代恢复后，再清理旧模板与镜像。

服务升级前备份 journal。二进制与 journal schema 发生变化时必须提供显式迁移，不能依赖手工改 JSON。

## 10. 生产差距

- 用 ate-api gRPC client 代替 `kubectl-ate` 子进程。
- 用 PostgreSQL 或同等级事务存储代替单机 JSON journal。
- 多副本按 Workspace 使用分布式锁和 fencing。
- 增加 mTLS/工作负载身份、Project/Workspace 授权和审计。
- router 增加连接数、空闲时间、总时长和主动 ping 策略。
- 自动检测 Worker 重注册和 WorkerAssignment 地址变化。
- 完整实现 Agent 执行、审批、成果保存和 bundle 重试的 Controller–Node 协议。
