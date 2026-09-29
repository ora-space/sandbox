# ORA Agent Substrate Sandbox

This repository contains the standalone sandbox adapter between ORA Cloud and [Agent Substrate](https://github.com/agent-substrate/substrate). It translates durable Cloud lifecycle effects into Actor, DATA Tag, and Workspace operations, and routes the ORA Controller to Ora Node v1 over a controlled WebSocket boundary.

The current implementation targets a single-cluster POC, integration testing, and runtime image packaging. Production deployments still require authenticated TLS ingress, Project/Workspace authorization, transactional journal storage, multi-replica fencing, and connection quotas.

## Layout

| Path | Purpose |
| --- | --- |
| `service/` | Lifecycle Effects API and controlled WebSocket router |
| `runtime/` | Ora Node v1 runtime, execution endpoint, and OCI Containerfile |
| `deploy/` | ActorTemplate and systemd examples |
| `examples/controller-demo/` | Minimal binary WebSocket protocol client |
| `docs/configuration.md` | Ports, flags, Controller settings, ActorTemplate, and security configuration |
| `docs/requirements-response.md` | Point-by-point response to both requirement rounds |
| `docs/effects-api.md` | Idempotency, recovery, lifecycle, and router semantics |
| `docs/deployment.md` | Build, image push, deployment, demo, logs, and image export |
| `docs/verification.md` | Evidence from the real gVisor Actor and DATA snapshot validation |

## Quick validation

Go 1.27.1 is required. Docker or a compatible OCI builder is required for the runtime image.

~~~bash
make test
make build
make image IMAGE=ora-sandbox-runtime:dev
~~~

Before deployment, update the image and snapshot storage in `deploy/ora-actor-template.json`, configure the Substrate atespace/template/kubeconfig/context in the service unit, and set the ORA Controller `effects_url`, `router_url`, `atespace`, and `controller_id`.

See [configuration](docs/configuration.md), [deployment](docs/deployment.md), and the [requirements response](docs/requirements-response.md).

## Deployment

The following is the shortest path for a control-side service connected to an Agent Substrate cluster. Review [configuration](docs/configuration.md) and the [production gaps](docs/deployment.md#10-生产差距) before a production rollout.

### 1. Clone and validate

~~~bash
git clone https://github.com/ora-space/sandbox.git
cd sandbox

make test
make test-race
make vet
make build
~~~

Go dependencies are committed under `vendor/`, so the Go compilation stage does not require a module proxy. Binaries are written to `bin/`.

### 2. Build and push the runtime image

~~~bash
IMAGE=registry.example.com/ora/sandbox-runtime:2026.09.29

make image IMAGE="$IMAGE"
docker push "$IMAGE"
docker inspect --format='{{index .RepoDigests 0}}' "$IMAGE"
~~~

Put the immutable digest in `deploy/ora-actor-template.json` at `containers[0].image`. Also update the atespace and template name, worker selector, snapshot storage, gVisor config, and resource limits.

~~~bash
kubectl-ate \
  --kubeconfig /opt/substrate-poc/config/kubeconfig \
  --context kind-substrate-poc \
  create actor-template -f deploy/ora-actor-template.json
~~~

ActorTemplates are immutable. Create a versioned template when the image, resources, or snapshot configuration changes, then point the lifecycle service to the new template.

### 3. Install the lifecycle service and router

Edit `deploy/ora-sandbox-service.service` first. Verify the atespace, template, controller ID, `kubectl-ate`, kubeconfig, context, internal router, listen addresses, and journal path. Parameters omitted from the unit use the defaults listed in [configuration](docs/configuration.md#生命周期服务启动参数).

~~~bash
sudo install -d -m 0755 /opt/substrate-poc/bin
sudo install -m 0755 bin/ora-sandbox-service /opt/substrate-poc/bin/
sudo install -m 0755 bin/ora-controller-demo /opt/substrate-poc/bin/
sudo install -d -m 0700 /opt/substrate-poc/ora-sandbox-service/state
sudo install -m 0644 deploy/ora-sandbox-service.service /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable --now ora-sandbox-service
~~~

### 4. Configure the ORA Controller

~~~yaml
effects_url: http://127.0.0.1:18002
router_url: ws://127.0.0.1:18001/ora-node/v1
atespace: ate-coding-poc
controller_id: ora-cloud-controller
~~~

These values must match the systemd unit and ActorTemplate. Across hosts, expose authenticated TLS `https://` and `wss://` endpoints. Expose `18001/18002` to the Controller; keep the atenet ingress on `18000` internal.

### 5. Verify the deployment

~~~bash
systemctl status ora-sandbox-service
journalctl -u ora-sandbox-service -n 100 --no-pager
ss -lntp | grep -E '18000|18001|18002'

# Valid but unknown effect ID: expect 404 not_found.
curl -i http://127.0.0.1:18002/effects/00000000-0000-4000-8000-000000000001

# No WebSocket Upgrade: expect 426.
curl -i http://127.0.0.1:18001/ora-node/v1
~~~

See the [full deployment guide](docs/deployment.md) for Actor creation, Node handshake, terminate, DATA Tag recovery, data deletion, logs, and image export.

## Current contract

~~~text
GET /effects/{effectId}
PUT /effects/{effectId}
GET /ora-node/v1       WebSocket Upgrade
~~~

The first release accepts `sandbox_ensure`, `sandbox_terminate`, and `workspace_data_delete`. Suspend/resume is not exposed to the Controller. A terminate operation may use an internal Substrate suspend to create a DATA snapshot. ORA frames remain binary WebSocket messages, and the router does not interpret application payloads. The maximum message size is 16 MiB.
