---
layout: documentation-single
title: Architecture
description: How Lynx is structured — workspaces, RBAC, the auth pipeline, snapshots, and the supervisor tree.
keywords: terraform-backend, lynx, terraform, architecture
comments: false
order: 6
hero:
    title: Architecture
    text: How Lynx is structured — workspaces, RBAC, the auth pipeline, snapshots, and the supervisor tree.
---

## The four-tier hierarchy

```
Workspace ─┬─ Project ─┬─ Environment ─┬─ Unit (state file)
           │           │                ├─ Unit
           │           │                └─ Unit
           │           └─ Environment
           └─ Project
```

* **Workspace** — top-level container, typically 1:1 with a repository.
* **Project** — logical grouping of related infra (e.g. `grafana`, `vpc`).
* **Environment** — deployment instance (e.g. `production`). Owns credentials and OIDC rules.
* **Unit** — a single root module's state, identified by sub-path within an environment.

State endpoints follow the URL: `/tf/<workspace>/<project>/<env>/<unit>/state`. The unit is optional — for plain Terraform (no Terragrunt) the URL is `/tf/<workspace>/<project>/<env>/state`.

## Authentication pipeline (`/tf/`)

`tf_controller.ex`'s `:auth` plug handles every request. It picks one of three paths based on the HTTP Basic username:

```
                        ┌───────────────────────┐
                        │ HTTP Basic credentials │
                        └───────────┬────────────┘
                                    │
                          ┌─────────┴──────────┐
                          │ username matches    │
                          │ an OIDC provider?   │
                          └─────────┬──────────┘
                          ┌────yes──┴──no─────┐
                          ▼                    ▼
                ┌──────────────────┐    ┌──────────────────┐
                │ OIDC JWT auth    │    │ contains "@"?    │
                │ - validate JWT   │    └────yes──┴──no───┘
                │ - eval rules     │         ▼            ▼
                │ - union perms    │   ┌──────────┐  ┌────────────┐
                └────────┬─────────┘   │ User+API │  │ Static env │
                         │             │   key    │  │ creds      │
                         │             └────┬─────┘  └─────┬──────┘
                         │                  │              │
                         └────────┬─────────┴──────────────┘
                                  ▼
                  {:ok, project, env, permissions :: MapSet}
```

The result is a permission set, not a boolean. Subsequent per-action plugs check whether `state:read`, `state:write`, `state:lock`, or `state:unlock` is in the set.

## Role-based access control

Permissions are atomic strings (`state:read`, `state:write`, `snapshot:restore`, ...). Roles are named bundles, stored in the `roles` and `role_permissions` tables.

Three roles ship by default:

| Role | Permissions |
|---|---|
| **Planner** | `state:read`, `state:lock`, `state:unlock`, `plan:check` |
| **Applier** | Planner's set + `state:write`, `snapshot:create` |
| **Admin** | Applier's set + `state:force_unlock`, `snapshot:restore`, `env:manage`, `project:manage`, `access:manage`, `oidc_rule:manage` |

`plan:check` authorizes uploads to `POST /tf/<workspace>/<project>/<env>/<unit?>/plan` for OPA evaluation. It's seeded into all three default roles so any caller that can plan can also evaluate the plan; revoke it on a custom role to lock policy evaluation down further.

Custom roles can be created at `/admin/roles` (super only). System roles carry `is_system: true` and can't be edited or deleted.

### Effective permissions

A user's effective permissions on a project are the **union** of:

1. Permissions from every team they belong to that's attached to the project (each `project_teams` row carries its own `role_id`).
2. Permissions from their direct `user_projects` row, if any.

Code: `Lynx.Context.RoleContext.effective_permissions(user, project)` returns a `MapSet`.

For OIDC tokens, the same union semantic applies across **every matching access rule** — so a token that matches both a permissive `planner` rule and a more specific `applier` rule gets applier's set. (Without union semantics, the auth result would depend on rule ordering.)

`super` users bypass per-project RBAC entirely.

### Per-environment overrides

Both `project_teams` and `user_projects` carry an optional `environment_id` column. `NULL` means "project-wide grant" — applies to every env. A non-null `environment_id` is an **env-specific override** that wins over project-wide grants when computing perms for that env.

`Lynx.Context.RoleContext.effective_permissions/3` (`(user, project, env)`) is the env-aware variant: if env-specific grants exist for the env, they're used in isolation; otherwise it falls back to project-wide. The 2-arg `effective_permissions/2` only considers project-wide grants — used by callers that don't have env context.

The Project Access UI surfaces this with per-env tabs in the Access card. The "All envs" tab shows project-wide grants; each env tab shows that env's overrides.

### Time-bounded grants

Both grant tables also carry an optional `expires_at` column. `NULL` = permanent (the default). Set `expires_at` and the grant is honored only until that timestamp; `effective_permissions` filters expired rows out at lookup time, and `Lynx.Worker.GrantExpirySweeper` deletes them once a minute (also emitting an `expired` audit event).

The Project Access card lets admins set an expiry when granting and clear it ("Make permanent") on existing grants.

## Lock semantics

Lynx tracks state locks in the `locks` table with `is_active`, `uuid`, `who`, and `operation` fields. Terraform always presents its lock UUID as `?ID=<uuid>` on subsequent state-write requests.

The state-push handler:

1. Checks if the env (and the specific sub-path) is locked.
2. If locked, compares the presented `?ID=` against the active lock's UUID.
3. If they match — the lock holder is writing their own state — allow.
4. If they don't match — or no `?ID=` was presented — return `423 Locked`.

This is what makes the canonical `lock → push state → unlock` cycle work for `terraform apply` and `terraform import`. (A pre-RBAC version of Lynx blocked the lock holder from writing too — see PR #20 for the fix.)

Force-unlock from the admin UI calls the same `LockContext.force_unlock/1` and is gated by the `state:unlock` permission. (Splitting force-unlock into its own permission is on the roadmap.)

## Snapshots

`Lynx.Worker.Snapshot` is a background worker that serializes a project, environment, or unit's state into a JSON blob and writes it to the `snapshots` table. Restore is the reverse — re-creating environments if missing and replaying state versions.

Snapshot scopes:

* **Project** — captures every environment and every state version under the project.
* **Environment** — captures one environment and all its units.
* **Unit** — captures one unit at one specific state version (or "latest").

Restoring requires `snapshot:restore` (admin role).

## Plan policy gates

Policy evaluation is factored behind a `Lynx.PolicyEngine` behaviour. The implementation is selected by application config:

```elixir
config :lynx, :policy_engine, Lynx.PolicyEngine.OPA   # production
config :lynx, :policy_engine, Lynx.PolicyEngine.Stub  # tests
```

The OPA implementation does an HTTP `POST` to `OPA_URL` with the plan JSON; the Stub returns deterministic fixtures so the test suite never reaches a network. Anything that conforms to the behaviour can drop in (Rego via OPA today; a future Cedar or in-process Rego engine could swap without touching callers).

### The bundle pattern

Policies live in Postgres (`policies` table). Lynx serves them at `GET /api/v1/opa/bundle.tar.gz` as a gzipped tarball, with each policy namespaced under `lynx.policy_<uuid>` so multiple policies coexist without symbol collisions. OPA polls this endpoint every 5–10 seconds — the standard [OPA Bundle API](https://www.openpolicyagent.org/docs/latest/management-bundles/). Bearer auth via the `OPA_BUNDLE_TOKEN` env var (Helm-managed) or DB-managed tokens minted from **Settings → OPA**.

This design is autoscaling-safe by construction. Under N Lynx replicas plus M OPA instances:

* Each OPA polls Lynx independently. There's no cross-pod messaging, no leader election, no shared cache to invalidate.
* OPA's local policy store is just a cache. Lynx's Postgres is canonical — so the worst-case staleness is one polling interval (5–10s).
* A Lynx replica that wants to evaluate a plan picks any OPA from `OPA_URL` (resolved by Kubernetes `Service` or your load balancer). Whichever OPA answers, the policy set is identical.

Concretely: a policy edit committed against any Lynx replica is visible to every OPA within ~10s without any orchestration.

### Apply gate

Per-environment fields `require_passing_plan` (bool, default false) and `plan_max_age_seconds` (int, default 1800) opt into the gate. When on, the state-write plug looks up the most recent passing `plan_checks` row for the same actor signature (`<actor_type>:<username>`) within the age window; absence returns `403 Apply gate: ...`. A passing plan-check is single-use — once consumed by an apply, it's marked spent.

## Supervisor tree

```
Lynx.Application
├── Lynx.Repo                # Ecto Postgres pool
├── LynxWeb.Telemetry        # VM + Phoenix metrics
├── Phoenix.PubSub           # cluster-wide PubSub
├── Finch                    # HTTP client (OIDC discovery, JWKS)
├── :sleeplocks              # named single-slot lock used by LockContext
├── Lynx.Worker.GrantExpirySweeper   # sweeps expired role grants once/min
└── LynxWeb.Endpoint         # Phoenix HTTP endpoint
```

`:sleeplocks` is registered with the supervisor so it survives across requests; serializes lock-acquisition attempts to avoid races between concurrent TF clients.

## Module layout

```
lib/lynx/
├── model/                   # Ecto schemas (one file per table)
├── context/                 # Resource-scoped data + business logic
├── service/                 # Cross-resource orchestration (auth, OIDC, SCIM, install, ...)
├── middleware/              # Plug pipelines (UI auth, API auth, SCIM auth, request logger)
├── worker/                  # Background workers
├── exception/               # Custom Plug exceptions
├── application.ex           # Supervision tree
└── repo.ex                  # Ecto.Repo

lib/lynx_web/
├── components/core_components.ex   # Function components (button, modal, badge, combobox, role_assignments_summary, ...)
├── live/                            # LiveViews (one per route)
├── controllers/                     # JSON / HTTP controllers
├── router.ex                        # Pipelines and route table
└── endpoint.ex
```

The `Lynx.Module.*` namespace was retired in PR #22. Resource-scoped code lives in `Context`; cross-resource orchestration lives in `Service`. See [Development]({{ site.baseurl }}/documentation/development/) for naming conventions inside contexts (`get_*` vs `fetch_*`, `_from_data`, `_for_user`).

## Where things live in the database

| Table | Notes |
|---|---|
| `users`, `users_session`, `users_meta` | User accounts; session stores `token` for cookie-auth. |
| `teams`, `users_teams`, `teams_meta` | Teams + membership. |
| `workspaces`, `projects`, `projects_meta`, `project_teams` | The hierarchy. `project_teams.role_id` controls team RBAC; `expires_at` makes it time-bounded; `environment_id` (nullable) is the per-env override. |
| `user_projects` | Direct (non-team) role grants. Same `expires_at` + `environment_id` columns. Composes via union with team grants. |
| `roles`, `role_permissions` | The RBAC layer. Three system roles (`is_system: true`) plus any custom roles created at `/admin/roles`. |
| `environments`, `environments_meta` | Per-project deploy targets. Owns username/secret. |
| `states`, `states_meta`, `locks`, `locks_meta` | Terraform state versions and locks (sub-path-aware). |
| `snapshots`, `snapshots_meta`, `tasks`, `tasks_meta` | Snapshots + their async tasks. |
| `oidc_providers`, `oidc_access_rules` | CI auth: providers + per-environment claim rules. |
| `policies` | Rego policy sources, with `enabled` + project/env attachment. Source of truth served to OPA via the bundle endpoint. |
| `plan_checks` | Every plan evaluation result (outcome, violations, actor signature, consumed-at). Backs the apply gate and the audit trail. |
| `opa_bundle_tokens` | DB-managed bearer tokens accepted on `/api/v1/opa/bundle.tar.gz`, minted from **Settings → OPA**. |
| `scim_tokens` | Bearer tokens for the SCIM 2.0 endpoint. |
| `audit_events` | Append-only log of meaningful actions. |
| `configs` | App-wide settings (app_name, app_url, app_key, SSO, SCIM toggles, ...). |
