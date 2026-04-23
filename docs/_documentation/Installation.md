---
layout: documentation-single
title: Installation
description: How to install and deploy Lynx using Docker, Helm, or a manual setup.
keywords: terraform-backend, lynx, terraform, installation
comments: false
order: 1
hero:
    title: Installation
    text: How to install and deploy Lynx using Docker, Helm, or a manual setup.
---

## What is Lynx?

Lynx is a self-hosted remote Terraform backend that stores state over HTTP with locking, versioning, and rollback. It replaces the need for S3 + DynamoDB or Terraform Cloud for state management. All it needs is PostgreSQL — no object storage required.

The admin UI organizes work into a `Workspace → Project → Environment → Unit` hierarchy. Access is governed by **role-based access control** (planner / applier / admin) granted to teams or individual users at the project level, plus OIDC access rules at the environment level for CI tokens.

This is a fork of [Clivern/Lynx](https://github.com/Clivern/Lynx) with SSO (OIDC + SAML), SCIM 2.0 provisioning, OIDC token authentication for CI/CD pipelines, RBAC, audit logging, multi-team project membership, unit-level state, and a frontend rewrite to Phoenix LiveView with Tailwind CSS.


## Docker

The quickest way to get Lynx running. You need Docker and docker-compose installed.

Run Lynx on port 4000:

```bash
wget https://raw.githubusercontent.com/Muon-Space/Lynx/main/docker-compose.yml \
    -O docker-compose.yml

docker-compose up -d
```

Run Lynx behind nginx on port 80:

```bash
wget https://raw.githubusercontent.com/Muon-Space/Lynx/main/docker-compose-nginx.yml \
    -O docker-compose.yml
wget https://raw.githubusercontent.com/Muon-Space/Lynx/main/nginx.conf \
    -O nginx.conf

docker-compose up -d
```

Run a 3-node Lynx cluster behind nginx:

```bash
wget https://raw.githubusercontent.com/Muon-Space/Lynx/main/docker-compose-cluster.yml \
    -O docker-compose.yml
wget https://raw.githubusercontent.com/Muon-Space/Lynx/main/nginx-cluster.conf \
    -O nginx-cluster.conf

docker-compose up -d
```

Open your browser to the configured URL (e.g. `http://localhost:4000`) and follow the install wizard to create your admin account.


## Helm (Kubernetes)

Lynx publishes an OCI Helm chart to GHCR:

```bash
helm install lynx oci://ghcr.io/muon-space/charts/lynx
```

The chart expects PostgreSQL to be provided externally. Database credentials are read from a pre-existing Kubernetes secret (`lynx-db-secret`), and the app secret from `lynx-app-secret`. An init container runs database migrations before the app starts.

See `charts/lynx/values.yaml` in the repository for all configurable values, including ingress, resource limits, and additional environment variables.

### Required environment variables

When deploying via Helm or any production Docker setup, the app reads these env vars at runtime (defined in `config/runtime.exs`):

| Variable | Required? | Notes |
|---|---|---|
| `APP_SECRET` | **yes** | Random 64-byte string used to sign cookies. Generate with `mix phx.gen.secret`. |
| `APP_HOST` | yes (prod) | Public host name for SSO redirect URLs and OpenAPI references. |
| `APP_HTTP_SCHEMA` | optional | `http` or `https`. Defaults to `http`. |
| `APP_PORT` | optional | Listening port. Defaults to `4000`. |
| `DB_USERNAME`, `DB_PASSWORD`, `DB_HOSTNAME`, `DB_DATABASE`, `DB_PORT` | **yes** | Postgres connection. |
| `DB_SSL` | optional | `on` to enable peer-verified TLS to Postgres. |
| `DB_CA_CERTFILE_PATH` | required if `DB_SSL=on` | Path to the CA bundle used to verify the Postgres server. |
| `AUTH_PASSWORD_ENABLED` | optional | `true`/`false`. Default `true`. Set to `false` to force SSO-only login. |
| `AUTH_SSO_ENABLED` | optional | `true`/`false`. Default `false`. |
| `SSO_PROTOCOL` | required if SSO on | `oidc` or `saml`. |
| `SSO_*` | required per protocol | Issuer/client/cert config. See `config/runtime.exs` for the full list. |
| `SCIM_ENABLED` | optional | `true`/`false`. Default `false`. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | optional | OpenTelemetry OTLP endpoint (e.g. `https://collector.example.com:4318`). When **unset**, the OTel SDK is disabled — zero added latency. When set, traces export to the configured collector. |
| `OTEL_EXPORTER_OTLP_HEADERS` | optional | Comma-separated headers for OTLP, e.g. `authorization=Bearer abc123`. |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | optional | `http_protobuf` (default) or `grpc`. |
| `OTEL_SERVICE_NAME` | optional | Service name in trace data. Defaults to `lynx`. |
| `OTEL_RESOURCE_ATTRIBUTES` | optional | Additional resource attrs, e.g. `deployment.environment=prod`. |
| `OTEL_SDK_DISABLED` | optional | Set to `true` to force the SDK off even if `OTEL_EXPORTER_OTLP_ENDPOINT` is set. |
| `OPA_URL` | optional | Base URL Lynx uses to query OPA for plan evaluation. Defaults to `http://localhost:8181`. |
| `OPA_TIMEOUT_MS` | optional | HTTP timeout (in ms) for the OPA evaluation call. Defaults to `5000`. |
| `OPA_BUNDLE_TOKEN` | optional | Bearer token OPA must present when polling `/api/v1/opa/bundle.tar.gz`. If unset, only DB-managed tokens minted from **Settings → OPA** are accepted. |

### OpenTelemetry traces

When `OTEL_EXPORTER_OTLP_ENDPOINT` is set, Lynx exports distributed traces. Phoenix HTTP requests and Ecto DB queries are auto-instrumented; explicit spans cover the operationally-interesting paths:

- Per-`/tf/` action: `tf.state.get`, `tf.state.push`, `tf.state.lock`, `tf.state.unlock` (workspace / project / env / sub_path attrs).
- `lynx.is_access_allowed`: which auth path matched (`oidc` / `user` / `env_secret`), project + env UUIDs, or the failure reason.
- `lynx.oidc.validate_access` + `lynx.jwt.validate_token` + `lynx.jwks.fetch`: provider name, claim count, JWKS cache hit/miss, validation failures.
- `lynx.snapshot_worker.{create,restore}_snapshots`: per worker tick.

Quick local verification with a Jaeger all-in-one container:

```bash
docker run -d --name jaeger -p 16686:16686 -p 4318:4318 \
  -e COLLECTOR_OTLP_ENABLED=true jaegertracing/all-in-one:latest

OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 \
OTEL_EXPORTER_OTLP_PROTOCOL=http_protobuf \
  make run
# Drive some /tf traffic, then open http://localhost:16686 → Service "lynx".
```


## OPA (plan policy gates)

Lynx evaluates Terraform plans against [Open Policy Agent](https://www.openpolicyagent.org/) policies before they're applied. OPA runs as a **separate process** (sidecar or centralized service) and pulls policies from Lynx via the OPA Bundle API every 5–10 seconds. This makes the setup autoscaling-safe — N Lynx replicas and M OPA instances all converge by independent polling, with Lynx's Postgres as the source of truth.

### Helm

Set `opa.enabled=true` in your values file:

```yaml
opa:
  enabled: true   # deploys an OPA sidecar/Deployment alongside Lynx
```

The chart auto-generates a `lynx-opa-bundle-token` Secret on first install, mounts it into the Lynx pod as `OPA_BUNDLE_TOKEN`, and configures the OPA pod's `services.lynx.credentials.bearer.token` to the same value. OPA polls Lynx's bundle endpoint (`/api/v1/opa/bundle.tar.gz`) using that bearer token.

### Docker

The `docker-compose.yml` files don't run OPA by default. To enable plan policy gates, add an OPA service to your compose file and set `OPA_BUNDLE_TOKEN` in `.env`:

```yaml
services:
  opa:
    image: openpolicyagent/opa:latest
    command: ["run", "--server", "--config-file=/config/opa.yaml"]
    ports:
      - "8181:8181"
    volumes:
      - ./opa-config.yaml:/config/opa.yaml:ro
```

`opa-config.yaml` should point OPA at Lynx's bundle endpoint:

```yaml
services:
  lynx:
    url: http://lynx:4000/api/v1/opa
    credentials:
      bearer:
        token: ${OPA_BUNDLE_TOKEN}
bundles:
  lynx:
    service: lynx
    resource: bundle.tar.gz
    polling:
      min_delay_seconds: 5
      max_delay_seconds: 10
```

Set `OPA_URL=http://opa:8181` and `OPA_BUNDLE_TOKEN=<random-string>` in the Lynx service's environment.

### Manual install

Download an [OPA release binary](https://github.com/open-policy-agent/opa/releases) and run it as a separate process or systemd unit:

```bash
opa run --server --config-file /etc/opa/config.yaml
```

Use the same `config.yaml` shape as the Docker example, pointing at your Lynx host. On Lynx, set `OPA_URL` to the OPA address (default `http://localhost:8181`) and `OPA_BUNDLE_TOKEN` to the bearer token OPA presents when polling. As an alternative to the env-var token, mint per-OPA tokens from **Settings → OPA** in the admin UI and configure each OPA with its own.

See [docs/usage](usage.md#plan-policy-gates) for the CI flow, the apply gate, and a sample Rego policy.


## Manual (Ubuntu)

Install Elixir, Erlang, and PostgreSQL:

```bash
apt-get update
apt-get install -y postgresql elixir erlang-dev make build-essential \
    erlang-os-mon inotify-tools erlang-xmerl
```

Set up the database:

```bash
sudo -u postgres psql -c "CREATE USER lynx WITH PASSWORD 'lynx';"
sudo -u postgres psql -c "ALTER USER lynx CREATEDB;"
sudo -u postgres psql -c "CREATE DATABASE lynx_dev OWNER lynx;"
```

Clone and configure:

```bash
mkdir -p /etc/lynx
cd /etc/lynx
git clone https://github.com/Muon-Space/Lynx.git app
cd /etc/lynx/app
cp .env.example .env.local  # edit database and app settings
```

Install dependencies and migrate:

```bash
export $(cat .env.local | xargs)
make deps
make migrate
```

Create a systemd service at `/etc/systemd/system/lynx.service`:

```ini
[Unit]
Description=Lynx

[Service]
Type=simple
Environment=HOME=/root
EnvironmentFile=/etc/lynx/app/.env.local
WorkingDirectory=/etc/lynx/app
ExecStart=/usr/bin/mix phx.server

[Install]
WantedBy=multi-user.target
```

```bash
systemctl enable lynx.service
systemctl start lynx.service
```

Open your browser and complete the install wizard.
