---
layout: documentation-single
title: Usage
description: Connecting Terraform / Terragrunt to Lynx; static credentials, user API keys, and OIDC token authentication.
keywords: terraform-backend, lynx, terraform
comments: false
order: 3
hero:
    title: Usage
    text: Connecting Terraform / Terragrunt to Lynx; static credentials, user API keys, and OIDC token authentication.
---

## The backend block

Click **View** on any environment row in the admin UI to copy a ready-to-paste backend block:

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

Place this in a `backend.tf` file and `terraform init`.

> [!TIP]
> If you use Terragrunt, the env's URL is reused for every unit by appending the unit name as a sub-path: `https://lynx.example.com/tf/<workspace>/<project>/<env>/<unit>/state`. Generate the backend block in your `root.hcl` so each unit picks it up automatically.

## Authentication

Lynx accepts three auth modes on `/tf/`, distinguished by username format:

| Username format | Password | Best for |
|---|---|---|
| `you@example.com` | User API key | Local dev, occasional manual ops |
| `github-actions` (provider name) | OIDC JWT | CI/CD pipelines |
| `<env-username>` (plain string) | Static env secret | Legacy / break-glass |

The standard Terraform env vars work for all three:

```bash
export TF_HTTP_USERNAME="..."
export TF_HTTP_PASSWORD="..."
```

### User API key auth

Find your API key on `/admin/profile` (click **Show** then **Copy** — the value is never embedded in HTML; it's pushed over the LiveView socket on demand).

```bash
export TF_HTTP_USERNAME="alice@example.com"
export TF_HTTP_PASSWORD="lynx_xxxxxxx"
```

Your effective permissions come from your role grants on the project (team grants ∪ direct grants). If you only have planner, `terraform plan` works but `terraform apply` returns 403.

### OIDC token auth (GitHub Actions example)

First, configure Lynx:

1. **Settings → OIDC Providers → + Add Provider**
   * Name: `github-actions` (this becomes the username Terraform uses)
   * Discovery URL: `https://token.actions.githubusercontent.com`
   * Audience: `lynx` (or any string you'll use as the OIDC `aud` claim)

2. On each environment row, click **OIDC** and add an access rule per role you want to grant. For a typical setup, you'll add **two** rules per environment:

   | Rule | Role | Claims |
   |---|---|---|
   | `planner` | Planner | `repository=Muon-Space/your-repo` |
   | `applier` | Applier | `repository=Muon-Space/your-repo` AND `environment=<env-name>` |

   The `environment` claim is only present when the calling **job** declares `environment: <name>` at the job level (a workflow input by that name does not add it). Using it on the applier rule prevents arbitrary jobs from issuing applies.

In your workflow:

```yaml
plan:
  runs-on: ubuntu-latest
  permissions:
    id-token: write    # required to mint an OIDC token
    contents: read
  steps:
    - uses: actions/checkout@v4
    - name: Authenticate Lynx via OIDC
      run: |
        TOKEN=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
                    "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=lynx" | jq -r '.value')
        echo "::add-mask::$TOKEN"
        echo "TF_HTTP_USERNAME=github-actions" >> "$GITHUB_ENV"
        echo "TF_HTTP_PASSWORD=$TOKEN" >> "$GITHUB_ENV"
    - run: terraform init && terraform plan

apply:
  runs-on: ubuntu-latest
  environment: production    # adds `environment=production` to the OIDC token
  permissions:
    id-token: write
    contents: read
  steps:
    # ...same as plan, then `terraform apply`
```

Lynx validates the JWT signature against the provider's JWKS (cached for 1h), checks expiry and audience, and evaluates **every** matching access rule. Permissions are the **union** of all matched rules' roles — so a token that matches both planner and applier rules gets applier's set.

> [!IMPORTANT]
> A common mis-config: the applier rule's `environment` claim doesn't match because the caller workflow doesn't declare `environment:` at the job level. The plan succeeds (planner matches on `repository` alone), but `terraform apply` returns 403 with `Insufficient role for state:write`. Fix: add the job-level `environment: <name>` directive.

### Static env credentials (legacy)

The env's auto-generated `username` + `secret` work as a Basic-auth bypass. They grant **full** access to that environment regardless of RBAC — useful for one-off scripts but the OIDC and API-key paths are preferable for any ongoing use.

## Locking and force-unlock

Terraform automatically locks the state during `plan`, `apply`, `import`, and a few other operations. Lynx records the lock with the caller's identity ("who"), the operation type, and a UUID. Subsequent state writes from the same caller (presenting the same `?ID=<uuid>` query param) are allowed; everyone else gets 423 Locked.

If a lock gets stuck (CI killed mid-apply, network blip during state push), force-unlock from the env page in the admin UI: click the red **Locked** badge on the env row. Force-unlocking requires the `state:unlock` permission.

You can also lock an environment preemptively from the same UI to block all Terraform operations during a maintenance window.

## Permission errors you might see

| Status | Body | Meaning |
|---|---|---|
| `403` | `Access is forbidden` | Auth failed (bad credentials / unknown provider / inactive user) |
| `403` | `Insufficient role for state:write` | Auth succeeded but your role doesn't grant this permission. For OIDC, check which rule actually matched. |
| `403` | `Insufficient role for state:lock` | Same as above. Plan needs `state:lock`; planner has it by default. |
| `423` | `Environment is locked` | The env has an active lock and you're not its holder. Force-unlock from the UI if it's stale. |
| `404` | `Not found` | Workspace/project/environment slug doesn't exist or you have no access path to it. |
