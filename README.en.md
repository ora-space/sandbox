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

## Current contract

~~~text
GET /effects/{effectId}
PUT /effects/{effectId}
GET /ora-node/v1       WebSocket Upgrade
~~~

The first release accepts `sandbox_ensure`, `sandbox_terminate`, and `workspace_data_delete`. Suspend/resume is not exposed to the Controller. A terminate operation may use an internal Substrate suspend to create a DATA snapshot. ORA frames remain binary WebSocket messages, and the router does not interpret application payloads. The maximum message size is 16 MiB.
