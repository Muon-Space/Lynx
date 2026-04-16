---
layout: documentation-single
title: Usage
description: How to connect Terraform to Lynx and authenticate with credentials or OIDC tokens.
keywords: terraform-backend, lynx, terraform
comments: false
order: 3
hero:
    title: Usage
    text: How to connect Terraform to Lynx and authenticate with credentials or OIDC tokens.
---

## Connecting Terraform

After creating a team, project, and environment, click the "View" button on your environment to see the backend configuration. It looks like this:

```hcl
terraform {
  backend "http" {
    address        = "http://localhost:4000/client/my-team/my-project/prod/state"
    lock_address   = "http://localhost:4000/client/my-team/my-project/prod/lock"
    unlock_address = "http://localhost:4000/client/my-team/my-project/prod/unlock"
    lock_method    = "POST"
    unlock_method  = "POST"
  }
}
```

Copy the `address`, `lock_address`, and `unlock_address` into a `backend.tf` file in your Terraform project.

Set the credentials as environment variables so they don't end up in version control:

```bash
export TF_HTTP_USERNAME="your-env-username"
export TF_HTTP_PASSWORD="your-env-secret"
```

Then run Terraform as usual:

```bash
terraform init
terraform plan
terraform apply
```

Lynx handles state storage and locking automatically. You can see the state version increment in the UI after each successful apply.


## OIDC token authentication

If you're running Terraform from a CI/CD system that supports OIDC (GitHub Actions, GitLab CI, etc.), you can authenticate without static secrets.

First, create an OIDC provider in Settings with the discovery URL for your CI system. For GitHub Actions, that's `https://token.actions.githubusercontent.com`.

Then, on your environment's OIDC rules page, create access rules that match the claims in the CI token (e.g. `repository=myorg/infra`, `environment=production`).

In your CI pipeline, set the Terraform credentials to use the provider name as the username and the OIDC token as the password:

```bash
export TF_HTTP_USERNAME="github-actions"    # matches the provider name in Lynx
export TF_HTTP_PASSWORD="$OIDC_TOKEN"       # the JWT from your CI system
```

Lynx validates the JWT signature against the provider's JWKS, checks expiry and audience, and evaluates your claim-based access rules. If any rule matches, access is granted.


## Locking and unlocking

Terraform automatically locks the state when running operations like `plan` and `apply`. If a lock gets stuck (e.g. a CI job was killed mid-apply), you can force-unlock it from the Lynx UI by clicking the lock status badge on the environment.

You can also lock an environment preemptively from the UI to prevent any Terraform operations during maintenance windows.
