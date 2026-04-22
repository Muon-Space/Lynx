---
layout: documentation-single
title: Getting Started
description: First-run walkthrough — admin install, your first workspace, project, environment, and Terraform connection.
keywords: terraform-backend, lynx, terraform
comments: false
order: 2
hero:
    title: Getting Started
    text: First-run walkthrough — admin install, your first workspace, project, environment, and Terraform connection.
---

## After installing

When you open Lynx for the first time, the install wizard creates an admin account and seeds:

* A **Default workspace**, a **planner** role, an **applier** role, and an **admin** role.
* The configs your deployment needs (`app_key`, `app_name`, `app_url`, `app_email`, `is_installed`).

You're now logged in as a `super` user — the only role that bypasses every per-project RBAC check. Treat super users like AWS root accounts: needed for setup, used sparingly afterward.

## Concepts you'll use

| Term | What it is |
|---|---|
| **Workspace** | Top-level container, usually one per repository or business unit (e.g. `terraform-okta`). |
| **Project** | A logical group of related infrastructure within a workspace (e.g. `grafana`). |
| **Environment** | A deployment instance of a project (e.g. `production`). Owns the credentials and OIDC rules. |
| **Unit** | A single root module within an environment with its own state file (e.g. `groups`). Optional — only meaningful with Terragrunt. |
| **Team** | A set of users that can be granted a role on a project. |
| **Role** | A bundle of permissions. Default roles: `planner` (read state), `applier` (write state), `admin` (everything). |

The hierarchy: `Workspace → Project → Environment → Unit`. Each unit has its own state file, keyed by the full URL path.

## Step 1 — Create a workspace

Navigate to **Workspaces** (`/admin/workspaces`). The Default workspace is pre-created; you can rename it or **+ Add Workspace**. Workspaces are usually 1:1 with a repository.

The slug becomes the first segment of the Terraform backend URL (`/tf/<workspace>/...`), so pick something stable like `terraform-okta` or `aws-govcloud`.

## Step 2 — Create a project

Click into your workspace, then **+ Add Project**. The project slug becomes the second URL segment.

## Step 3 — Create an environment

Open the project and click **+ Add Environment**. The dialog generates a username + secret — these are the static credentials for the legacy auth path. You can keep them as a fallback or ignore them and use OIDC / user-API-key auth.

## Step 4 — Connect Terraform

Click **View** on the environment row. Lynx shows a ready-to-paste backend block:

```hcl
terraform {
  backend "http" {
    address        = "http://localhost:4000/tf/<workspace>/<project>/<env>/state"
    lock_address   = "http://localhost:4000/tf/<workspace>/<project>/<env>/lock"
    unlock_address = "http://localhost:4000/tf/<workspace>/<project>/<env>/unlock"
    lock_method    = "POST"
    unlock_method  = "POST"
  }
}
```

Set credentials as env vars (one of):

```bash
# Option A — your personal API key (find it on /admin/profile)
export TF_HTTP_USERNAME="you@example.com"
export TF_HTTP_PASSWORD="lynx_xxxxx"

# Option B — env's static credentials
export TF_HTTP_USERNAME="<env-username>"
export TF_HTTP_PASSWORD="<env-secret>"

# Option C — OIDC token from CI (see usage docs)
export TF_HTTP_USERNAME="github-actions"
export TF_HTTP_PASSWORD="$ACTIONS_ID_TOKEN"
```

Then `terraform init && terraform plan && terraform apply`.

## Step 5 — Grant access to teammates

Open the project and scroll to the **Project Access** card.

* **Teams** — pick an existing team and assign a role (planner / applier / admin, or any custom role you've defined at `/admin/roles`). Everyone in the team gets that role on this project.
* **Individual users** — pick a user and assign a role directly. Their effective permissions are the union of their direct grant and any team grants.
* **Optional expiry** — set "Expires" on a grant for time-bounded access ("Bob is applier on prod for the next 4 hours"). A sweeper revokes expired grants automatically.
* **Per-env overrides** — the per-env tabs let you scope a grant to a single environment instead of the whole project. Useful for "team A is applier in dev, planner in prod."

The role badge shows in the column. Roles are described under [Role-based access control](#role-based-access-control) below.

## Step 6 — (CI) Configure OIDC token auth

If your CI is GitHub Actions, GitLab CI, or any other OIDC-capable runner, you can authenticate without static secrets:

1. Go to **Settings → OIDC Providers** and add the provider (for GitHub Actions: `https://token.actions.githubusercontent.com`).
2. On the environment row, click **OIDC** to add an access rule. Pick:
   * **Provider** — the one you just created.
   * **Role** — `planner` for plan-only jobs, `applier` for apply jobs.
   * **Claims** — match the JWT claims, e.g. `repository=Muon-Space/terraform-okta` and `environment=grafana-production`. All claims must match (AND logic).

In your workflow, mint a token and pass it to Terraform:

```yaml
- name: Authenticate Lynx via OIDC
  env:
    GITHUB_SERVER_URL: ${{ github.server_url }}
  run: |
    TOKEN=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
                "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=lynx" | jq -r '.value')
    echo "::add-mask::$TOKEN"
    echo "TF_HTTP_USERNAME=github-actions" >> "$GITHUB_ENV"
    echo "TF_HTTP_PASSWORD=$TOKEN" >> "$GITHUB_ENV"
```

> [!IMPORTANT]
> The OIDC `environment` claim is only present in the JWT if the calling **job** declares `environment: <name>` at the job level — not just as a workflow input. Without that, only `repository` is in the token and only rules that match on `repository` alone will succeed.

## Role-based access control

| Role | Permissions | Use for |
|---|---|---|
| **Planner** | `state:read`, `state:lock`, `state:unlock` | PR plan jobs, observers |
| **Applier** | Planner + `state:write`, `snapshot:create` | Deploy jobs, on-call engineers |
| **Admin** | Applier + `snapshot:restore`, `env:manage`, `project:manage`, `access:manage`, `oidc_rule:manage` | Project owners |

A user's effective permissions on a project are the **union** of every grant — every team they're in plus any direct grant. Stacking grants is additive, never overriding.

`super` users bypass per-project RBAC. Reserve for the platform team.

## SSO and SCIM (optional)

`/admin/settings` has tabs for **SSO** (OIDC + SAML 2.0 login) and **SCIM** (automated user/group sync from your IdP). Both are off by default; turning them on doesn't disable password login unless you also flip the **Password Login Enabled** toggle.

SCIM Groups map to Lynx Teams. When your IdP pushes a group with members, Lynx creates the corresponding team and assigns users. User deactivation (`active: false`) immediately invalidates that user's sessions.

## Where to next

* [Usage]({{ site.baseurl }}/documentation/usage/) — the full Terraform / CI integration story
* [API]({{ site.baseurl }}/documentation/api-and-tf-provider/) — REST API and SCIM endpoints
* [Development]({{ site.baseurl }}/documentation/development/) — running Lynx locally for development
