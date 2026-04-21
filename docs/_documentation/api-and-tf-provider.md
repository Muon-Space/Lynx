---
layout: documentation-single
title: API
description: Lynx REST API and SCIM 2.0 endpoints.
keywords: terraform-backend, lynx, terraform, api, scim
comments: false
order: 4
hero:
    title: API
    text: Lynx REST API and SCIM 2.0 endpoints.
---

## REST API — `/api/v1/*`

JSON API for managing every resource in Lynx. All endpoints require an API key in the `x-api-key` header:

```
x-api-key: <your-api-key>
```

Find your API key on `/admin/profile` (Show → Copy). The key is never embedded in the rendered HTML; it's pushed over the LiveView socket on demand.

The OpenAPI 3.0 spec is published at `/api/v1/openapi.yml` on every running instance — feed it to Swagger UI, Postman, or any OpenAPI-aware tool. The spec at the repo root (`api.yml`) is the same file.

### Response conventions

* **JSON keys** — camelCase for compound names (`createdAt`, `totalCount`, `errorMessage`, `apiKey`, `isLocked`); single-word keys stay bare (`id`, `name`, `slug`, `role`).
* **Resource IDs** — exposed as `id` (sourced from the underlying UUID); never `uuid`.
* **Pagination** — `{ <resource>: [...], limit, offset, totalCount }`.
* **Errors** — `{ "errorMessage": "..." }`.
* **Status codes** — `200` for read/update, `201` for create, `204` for delete, `403` for forbidden (role check failed), `404` for not found.

### Endpoints

#### Users (super only)

```
GET    /api/v1/user
POST   /api/v1/user
GET    /api/v1/user/:uuid
PUT    /api/v1/user/:uuid
DELETE /api/v1/user/:uuid
```

#### Teams

```
GET    /api/v1/team
POST   /api/v1/team
GET    /api/v1/team/:uuid
PUT    /api/v1/team/:uuid
DELETE /api/v1/team/:uuid
```

#### Projects

```
GET    /api/v1/project
POST   /api/v1/project
GET    /api/v1/project/:uuid
PUT    /api/v1/project/:uuid
DELETE /api/v1/project/:uuid
```

Project access is filtered to whatever you have permissions to see (super sees everything).

#### Environments

```
GET    /api/v1/project/:p_uuid/environment
POST   /api/v1/project/:p_uuid/environment
GET    /api/v1/project/:p_uuid/environment/:e_uuid
PUT    /api/v1/project/:p_uuid/environment/:e_uuid
DELETE /api/v1/project/:p_uuid/environment/:e_uuid

POST   /api/v1/environment/:e_uuid/lock      # admin force-lock
POST   /api/v1/environment/:e_uuid/unlock    # admin force-unlock
```

#### Snapshots

```
GET    /api/v1/snapshot
POST   /api/v1/snapshot
GET    /api/v1/snapshot/:uuid
PUT    /api/v1/snapshot/:uuid
DELETE /api/v1/snapshot/:uuid
POST   /api/v1/snapshot/restore/:uuid       # restore (admin only)
```

#### Tasks

```
GET    /api/v1/task/:uuid
```

#### OIDC Providers (super only)

```
GET    /api/v1/oidc_provider
POST   /api/v1/oidc_provider
PUT    /api/v1/oidc_provider/:uuid
DELETE /api/v1/oidc_provider/:uuid
```

#### OIDC Access Rules (super only)

```
GET    /api/v1/oidc_rule/:environment_id
POST   /api/v1/oidc_rule
DELETE /api/v1/oidc_rule/:uuid
```

The rule body includes `role_id` to pick the role granted on a successful claim match.

#### Profile / API key

```
POST   /api/v1/action/update_profile        # name, email, password
GET    /api/v1/action/fetch_api_key         # returns your current key
POST   /api/v1/action/rotate_api_key        # generate a new one
```

#### Settings (super only)

```
PUT    /api/v1/action/update_settings       # general settings (app_name, app_url, etc.)
PUT    /api/v1/action/update_sso_settings   # SSO configs

POST   /api/v1/action/saml_cert             # generate an SP cert for SAML
POST   /api/v1/action/scim_token            # mint a new SCIM bearer token (returned ONCE)
GET    /api/v1/action/scim_tokens           # list (token values are masked)
DELETE /api/v1/action/scim_token/:uuid      # revoke
```

#### Audit log

```
GET    /api/v1/audit
```

Query params: `action`, `resource_type`, `actor_id`, `offset`, `limit`. Returns `{ events, total }`.

## Terraform HTTP backend — `/tf/*`

The backend Terraform talks to. Documented in [Usage]({{ site.baseurl }}/documentation/usage/).

```
GET    /tf/:workspace/:project/:env/state
POST   /tf/:workspace/:project/:env/state
POST   /tf/:workspace/:project/:env/lock
POST   /tf/:workspace/:project/:env/unlock
```

Sub-paths (Terragrunt units) are supported via the `*rest` segment:

```
GET    /tf/:workspace/:project/:env/<unit>/state
POST   /tf/:workspace/:project/:env/<unit>/state
... (same for lock/unlock)
```

Auth is HTTP Basic (`TF_HTTP_USERNAME` / `TF_HTTP_PASSWORD`). Each operation maps to a permission:

| Operation | Permission required |
|---|---|
| `GET /state` | `state:read` |
| `POST /state` | `state:write` |
| `POST /lock` | `state:lock` |
| `POST /unlock` | `state:unlock` |

A legacy `/client/*` route exists for backward compatibility with old clients that don't include the workspace segment — Lynx resolves the workspace from the project slug. New integrations should use `/tf/`.

## SCIM 2.0 — `/scim/v2/*`

Implements the SCIM 2.0 spec for automated user and group provisioning from IdPs (Okta, Azure AD, JumpCloud, etc.).

Auth: bearer token issued from **Settings → SCIM** in the admin UI.

### Discovery

```
GET    /scim/v2/ServiceProviderConfig
GET    /scim/v2/ResourceTypes
GET    /scim/v2/Schemas
```

### Users

```
GET    /scim/v2/Users           # list (supports filter, sort, pagination)
POST   /scim/v2/Users           # provision
GET    /scim/v2/Users/:id
PUT    /scim/v2/Users/:id       # full replace
PATCH  /scim/v2/Users/:id       # partial update (e.g. `active: false` to deactivate)
DELETE /scim/v2/Users/:id
```

User deactivation immediately invalidates all of that user's sessions.

### Groups

```
GET    /scim/v2/Groups
POST   /scim/v2/Groups
GET    /scim/v2/Groups/:id
PUT    /scim/v2/Groups/:id
PATCH  /scim/v2/Groups/:id      # add/remove/replace members
DELETE /scim/v2/Groups/:id
```

SCIM Groups map to Lynx Teams. Members added via PATCH are immediately reflected in team membership and any project role grants the team holds.

## OpenAPI spec

A `api.yml` file at the repo root describes the REST API in OpenAPI 3.0 format. Use it with Swagger UI, Postman, or any OpenAPI-aware tool. (Note: this file may lag the running API — open an issue if you find a mismatch.)
