---
layout: documentation-single
title: API
description: How to use the Lynx RESTful API and SCIM 2.0 endpoints.
keywords: terraform-backend, lynx, terraform, api, scim
comments: false
order: 4
hero:
    title: API
    text: How to use the Lynx RESTful API and SCIM 2.0 endpoints.
---

## RESTful API

Lynx exposes a JSON API for managing users, teams, projects, environments, and snapshots programmatically. All endpoints require an API key passed as a Bearer token in the `Authorization` header.

You can find your API key on the Profile page in the admin UI.

### Authentication

```
Authorization: Bearer <your-api-key>
```

### Endpoints

**Users** — `GET /api/v1/user`, `POST /api/v1/user`, `GET /api/v1/user/:uuid`, `PUT /api/v1/user/:uuid`, `DELETE /api/v1/user/:uuid`

**Teams** — `GET /api/v1/team`, `POST /api/v1/team`, `GET /api/v1/team/:uuid`, `PUT /api/v1/team/:uuid`, `DELETE /api/v1/team/:uuid`

**Projects** — `GET /api/v1/project`, `POST /api/v1/project`, `GET /api/v1/project/:uuid`, `PUT /api/v1/project/:uuid`, `DELETE /api/v1/project/:uuid`

**Environments** — `GET /api/v1/project/:p_uuid/environment`, `POST /api/v1/project/:p_uuid/environment`, `GET /api/v1/project/:p_uuid/environment/:e_uuid`, `PUT /api/v1/project/:p_uuid/environment/:e_uuid`, `DELETE /api/v1/project/:p_uuid/environment/:e_uuid`

**Environment locking** — `POST /api/v1/environment/:uuid/lock`, `POST /api/v1/environment/:uuid/unlock`

**Snapshots** — `GET /api/v1/snapshot`, `POST /api/v1/snapshot`, `GET /api/v1/snapshot/:uuid`, `PUT /api/v1/snapshot/:uuid`, `DELETE /api/v1/snapshot/:uuid`, `POST /api/v1/snapshot/restore/:uuid`

**OIDC Providers** — `GET /api/v1/oidc_provider`, `POST /api/v1/oidc_provider`, `PUT /api/v1/oidc_provider/:uuid`, `DELETE /api/v1/oidc_provider/:uuid`

**OIDC Access Rules** — `GET /api/v1/oidc_rule/:environment_id`, `POST /api/v1/oidc_rule`, `DELETE /api/v1/oidc_rule/:uuid`

**Audit Log** — `GET /api/v1/audit` (supports `?action=`, `?resource_type=`, `?offset=`, `?limit=` query params)

### Responses

Successful requests return JSON with the resource data. List endpoints include `limit`, `offset`, and `totalCount` metadata. Create returns `201`, update and get return `200`, delete returns `204`.


## SCIM 2.0

Lynx implements a SCIM 2.0 server at `/scim/v2/` for automated user and group provisioning from identity providers like Okta, Azure AD, and others.

SCIM authentication uses bearer tokens generated from the Settings page in the admin UI.

The SCIM server supports Users and Groups with full CRUD, PATCH operations (add/remove/replace members), list with filtering, and the standard discovery endpoints (`/ServiceProviderConfig`, `/ResourceTypes`, `/Schemas`).

SCIM Groups map to Lynx Teams. When your IdP pushes a group with members, Lynx creates the corresponding team and assigns users. User deactivation (`active: false`) immediately invalidates all sessions.
