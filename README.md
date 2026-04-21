<p align="center">
    <img alt="Lynx Logo" src="/assets/img/logo.png?v=0.12.9" width="400" />
    <h3 align="center">Lynx</h3>
    <p align="center">A Fast, Secure and Reliable Terraform Backend, Set up in Minutes.</p>
    <p align="center">
        <a href="https://github.com/Muon-Space/Lynx/actions/workflows/server_ci.yml">
            <img src="https://github.com/Muon-Space/Lynx/actions/workflows/server_ci.yml/badge.svg"/>
        </a>
        <a href="https://github.com/Muon-Space/Lynx/releases">
            <img src="https://img.shields.io/badge/Version-0.12.9-1abc9c.svg">
        </a>
        <a href="https://ghcr.io/muon-space/lynx">
            <img src="https://img.shields.io/badge/GHCR-latest-1abc9c.svg">
        </a>
        <a href="https://github.com/Muon-Space/Lynx/blob/main/LICENSE">
            <img src="https://img.shields.io/badge/LICENSE-MIT-orange.svg">
        </a>
    </p>
</p>
<br/>

Lynx is a self-hosted remote Terraform backend built in Elixir with Phoenix LiveView. It stores state over HTTP, handles locking, gives your team a clean admin UI for access control, and authenticates CI pipelines via OIDC — no static secrets needed.

It replaces the need for S3 + DynamoDB or Terraform Cloud for state management. PostgreSQL is the only required dependency.

This is a fork of [Clivern/Lynx](https://github.com/Clivern/Lynx) with significant additions: SSO (OIDC + SAML), SCIM 2.0 provisioning, OIDC token authentication for CI/CD pipelines, audit logging, **role-based access control** (planner / applier / admin), workspaces, unit-level state, and a full frontend rewrite to Phoenix LiveView with Tailwind CSS.

## Table of Contents

- [How Lynx is organized](#how-lynx-is-organized)
- [Connecting Terraform](#connecting-terraform)
- [Authentication options](#authentication-options)
- [Role-based access control](#role-based-access-control)
- [Snapshots](#snapshots)
- [Audit log](#audit-log)
- [SSO and SCIM](#sso-and-scim)
- [REST API](#rest-api)
- [Quick start](#quick-start)
- [Running locally for development](#running-locally-for-development)

## How Lynx is organized

Terminology:

* **Workspace** — top-level container, typically one per repository or business unit (e.g. `terraform-okta`, `aws-govcloud`).
* **Project** — a logical group of related infrastructure within a workspace (e.g. `grafana`, `vpc`).
* **Environment** — a deployment instance of a project (e.g. `production`, `staging`). Each environment has its own state endpoint and credentials.
* **Unit** — a single root module within an environment, with its own isolated state file (e.g. `groups`, `dns`). Maps directly to a Terragrunt unit.

The hierarchy is `Workspace → Project → Environment → Unit`. State is keyed by the full path, so two units never collide.

State endpoints follow this URL scheme:

```
https://lynx.example.com/tf/<workspace>/<project>/<environment>/<unit>/state
https://lynx.example.com/tf/<workspace>/<project>/<environment>/<unit>/lock
https://lynx.example.com/tf/<workspace>/<project>/<environment>/<unit>/unlock
```

The `<unit>` segment is optional — for plain Terraform (no Terragrunt) you can omit it.

Access control is composed at the project level:

* **Teams** are attached to projects with a role (planner, applier, or admin).
* **Individual users** can be granted a role on a project directly.
* **OIDC access rules** authorize CI tokens at the environment level, also with a role.

A user's effective permissions on a project are the **union** of all their team grants and any direct grant.

## Connecting Terraform

Once you've created a project + environment in Lynx, click **View** on the environment row to see a ready-to-paste backend block. It looks like this:

```hcl
terraform {
  backend "http" {
    address        = "https://lynx.example.com/tf/<workspace>/<project>/<env>/state"
    lock_address   = "https://lynx.example.com/tf/<workspace>/<project>/<env>/lock"
    unlock_address = "https://lynx.example.com/tf/<workspace>/<project>/<env>/unlock"
    lock_method    = "POST"
    unlock_method  = "POST"
  }
}
```

Set credentials as environment variables — never hard-code them in `backend.tf`:

```bash
export TF_HTTP_USERNAME="your-username"
export TF_HTTP_PASSWORD="your-secret-or-token"
terraform init
terraform plan
terraform apply
```

Terragrunt picks up the same env vars since it shells out to Terraform.

> [!TIP]
> Lynx automatically locks the state during `plan`, `apply`, and `import`. If a lock gets stuck (e.g. a CI job was killed mid-apply), force-unlock from the env page in the admin UI.

## Authentication options

Lynx accepts **three** auth modes on the `/tf/` backend, picked automatically based on the username format:

| Username format | Password | When to use |
|---|---|---|
| Email (`alice@example.com`) | User API key (from Profile page) | Local development, occasional manual ops |
| OIDC provider name (`github-actions`) | OIDC JWT | CI/CD pipelines |
| Plain string (`tf-user`) | Static env secret | Legacy / break-glass |

User and OIDC paths both resolve to a **role** that determines what operations are allowed. Static env credentials bypass RBAC and grant full access — useful for one-off scripts but the others are preferable.

For CI, set the standard Terraform env vars:

```bash
export TF_HTTP_USERNAME="github-actions"   # matches the provider name in Lynx
export TF_HTTP_PASSWORD="$ACTIONS_ID_TOKEN" # GitHub Actions OIDC JWT
```

See [docs/usage](docs/_documentation/usage.md) for the full GitHub Actions snippet, GitLab CI example, and how to mint a token in the workflow.

## Role-based access control

Lynx ships three system roles, made up of atomic permissions:

| Role | Permissions |
|---|---|
| **Planner** | `state:read`, `state:lock`, `state:unlock` — enough to run `terraform plan` |
| **Applier** | Planner's set + `state:write`, `snapshot:create` — enough to run `terraform apply` |
| **Admin** | Applier's set + `snapshot:restore`, `env:manage`, `project:manage`, `access:manage`, `oidc_rule:manage` |

> [!IMPORTANT]
> `terraform plan` always acquires a state lock by default (`-lock=false` is opt-in), so Planner needs `state:lock`/`state:unlock` to be functional. Applier is what differentiates "can mutate state" from "read-only."

Roles are **assigned per project** for teams and individual users, and **per environment** for OIDC rules. A user's effective permission set on a project is the union of every grant they have (team grants + direct grants).

Manage role assignments from the **Project Access** card on each project page (`/admin/projects/<uuid>`). Manage OIDC rule roles from the **OIDC** button on each environment row.

Global `super` users bypass per-project RBAC entirely — useful for the platform team but should be granted sparingly.

## Snapshots

Snapshots are point-in-time backups of project, environment, or unit state. Take a snapshot from the Snapshots page; restore with one click. Restoring an environment-scope snapshot recreates missing environments and replays state versions; restoring a unit-scope snapshot only replays state for that one unit.

Restoring requires the `snapshot:restore` permission (admin role).

## Audit log

Every meaningful action — create / update / delete on any resource, lock / unlock, state push, role grant, snapshot restore — is logged with actor, timestamp, resource, and optional metadata. View at `/admin/audit`. Filter by action type, resource type, or actor (super only).

## SSO and SCIM

Lynx supports OIDC and SAML 2.0 login with JIT user provisioning. SCIM 2.0 lets your IdP (Okta, Azure AD, etc.) automatically sync users and groups into Lynx teams. All configuration lives in the **Settings** page (`/admin/settings`) under the SSO and SCIM tabs.

User deactivation via SCIM (`active: false`) immediately invalidates all of that user's sessions.

## REST API

Lynx exposes a JSON API at `/api/v1/*` for programmatic management of users, teams, projects, environments, snapshots, OIDC providers, and audit events. All endpoints require a Bearer token (your user API key) in the `Authorization` header.

```bash
curl -H "Authorization: Bearer $LYNX_API_KEY" https://lynx.example.com/api/v1/project
```

The SCIM 2.0 API at `/scim/v2/` supports Users and Groups with full CRUD, filtering, and PATCH operations for IdP integration.

See [docs/api-and-tf-provider](docs/_documentation/api-and-tf-provider.md) for the full endpoint list.

## Quick start

You need Docker and docker-compose. Lynx requires PostgreSQL — no object storage needed.

Run Lynx on port 4000:

```bash
wget https://raw.githubusercontent.com/Muon-Space/Lynx/main/docker-compose.yml \
    -O docker-compose.yml

docker-compose up -d
```

Open `http://localhost:4000` and follow the install wizard to create your admin account. The wizard creates a "Default" workspace; you can rename it or add more from `/admin/workspaces`.

To run behind nginx on port 80, or as a 3-node cluster, see the [Installation guide](docs/_documentation/Installation.md).

For Kubernetes, there's a Helm chart on GHCR:

```bash
helm install lynx oci://ghcr.io/muon-space/charts/lynx
```

## Running locally for development

Prerequisites: Elixir 1.19+, Erlang/OTP 28+, PostgreSQL 16+.

```bash
docker run -d --name lynx-pg -p 5432:5432 \
  -e POSTGRES_USER=lynx -e POSTGRES_PASSWORD=lynx -e POSTGRES_DB=lynx_dev \
  postgres:16

git clone git@github.com:Muon-Space/Lynx.git && cd Lynx

make deps       # fetch dependencies
make migrate    # create + migrate the database (runs ecto.setup)
make run        # start the dev server on port 4000
```

Other Makefile targets:

```bash
make test        # run the test suite (mix test --trace)
make ci          # run mix coveralls (enforces 70% coverage gate)
make build       # compile with --warnings-as-errors
make fmt         # format code
make fmt_check   # check formatting without modifying
```

The dev server supports live reloading — changes to LiveView modules, components, and HEEx templates are reflected in the browser automatically.

> [!TIP]
> If your local PostgreSQL uses different credentials, override via environment variables: `DB_USERNAME`, `DB_PASSWORD`, `DB_HOSTNAME`, `DB_DATABASE`, `DB_PORT`. Defaults are in `config/dev.exs`.

See [docs/development](docs/_documentation/development.md) for the architecture overview, contributing notes, and the test infrastructure (LiveCase, ConnCase, factories, coverage gate).

## License

© 2023 [Clivern](https://github.com/Clivern). Released under the [MIT License](https://opensource.org/licenses/mit-license.php).

This fork is maintained by [Muon Space](https://github.com/Muon-Space).
