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

## Plan policy gates

Lynx evaluates Terraform plans against [Open Policy Agent](https://www.openpolicyagent.org/) policies before they're applied. Author a policy in **Admin → Policies**, attach it to a project or environment, and CI uploads the plan JSON for evaluation. Optionally, enable the **apply gate** on an environment so a state-write requires a recent passing plan-check from the same actor — single-use.

The plan-check endpoint is:

```
POST /tf/<workspace>/<project>/<env>/<unit?>/plan
```

It accepts the JSON output of `terraform show -json <planfile>` as the request body, runs every effective OPA policy attached to the env (env-scoped + project-scoped), and returns:

```json
{
  "id": "1f3c4f2e-...-...",
  "outcome": "passed",
  "violations": [],
  "policiesEvaluated": 3
}
```

`outcome` is `passed`, `failed`, or `errored`. All three return HTTP 200 — non-2xx is reserved for malformed body, auth failure, or engine failure. Every plan-check is persisted (auditable) regardless of outcome. The endpoint requires the new `plan:check` permission, which is granted to planner / applier / admin by default.

### CI flow

The full CI cycle becomes:

1. `terraform plan -out=tfplan.binary`
2. `terraform show -json tfplan.binary > plan.json`
3. `curl -X POST .../plan -d @plan.json` and check `outcome`
4. If `passed`, run `terraform apply tfplan.binary`

GitHub Actions:

```yaml
plan-and-apply:
  runs-on: ubuntu-latest
  environment: production
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
        echo "LYNX_TOKEN=$TOKEN" >> "$GITHUB_ENV"

    - run: terraform init
    - run: terraform plan -out=tfplan.binary
    - run: terraform show -json tfplan.binary > plan.json

    - name: Submit plan to Lynx for policy evaluation
      run: |
        RESULT=$(curl -sS -X POST \
          -u "github-actions:$LYNX_TOKEN" \
          -H "Content-Type: application/json" \
          --data @plan.json \
          https://lynx.example.com/tf/acme/web/production/plan)

        echo "$RESULT" | jq .
        OUTCOME=$(echo "$RESULT" | jq -r .outcome)

        if [ "$OUTCOME" != "passed" ]; then
          echo "Plan rejected by policy:"
          echo "$RESULT" | jq -r '.violations[] | "  - \(.policyName): \(.messages | join("; "))"'
          exit 1
        fi

    - run: terraform apply -auto-approve tfplan.binary
```

### Apply gate

Plan-checks are advisory by default — CI is free to apply without uploading the plan. To make policy evaluation **required**, open the environment's **Settings** card and enable:

* **Require passing plan** (`require_passing_plan`) — every state-write must be backed by a passing plan-check.
* **Plan max age** (`plan_max_age_seconds`, default `1800`) — how recent the plan-check must be.

When the gate is on, a state-write without a fresh, unconsumed, passing plan-check from the **same actor** (matched by `<actor_type>:<username>`) returns:

```
HTTP/1.1 403 Forbidden

Apply gate: no passing plan-check found for this caller within the last 1800s
```

A passing plan-check authorizes exactly one apply — single-use semantics. Run a fresh plan-check before each apply.

### Writing policies

Policies are Rego, evaluated against the `terraform show -json` output. Lynx targets OPA 1.0+, which requires the `if` keyword on rule bodies and `contains` on partial-set rules. A simple "block public S3 buckets" rule:

```rego
package main

deny contains msg if {
  some i
  resource := input.resource_changes[i]
  resource.type == "aws_s3_bucket"
  resource.change.after.acl == "public-read"
  msg := sprintf("S3 bucket %s is public", [resource.address])
}
```

Each `deny` message becomes a violation entry in the plan-check response. Lynx serves the full policy set to OPA via the Bundle API, so edits in the admin UI propagate to every OPA instance within a few seconds — no redeploy needed.

> [!TIP]
> Test policies locally with `opa eval -d policy.rego -i plan.json 'data.main.deny'` before attaching them in the UI. The same Rego runs in production.

## Permission errors you might see

| Status | Body | Meaning |
|---|---|---|
| `403` | `Access is forbidden` | Auth failed (bad credentials / unknown provider / inactive user) |
| `403` | `Insufficient role for state:write` | Auth succeeded but your role doesn't grant this permission. For OIDC, check which rule actually matched. |
| `403` | `Insufficient role for state:lock` | Same as above. Plan needs `state:lock`; planner has it by default. |
| `423` | `Environment is locked` | The env has an active lock and you're not its holder. Force-unlock from the UI if it's stale. |
| `404` | `Not found` | Workspace/project/environment slug doesn't exist or you have no access path to it. |
