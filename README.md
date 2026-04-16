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

Lynx is a remote Terraform backend built in Elixir with Phoenix LiveView. It stores your Terraform state over HTTP, handles locking, and gives your team a clean admin UI to manage projects, environments, and access control.

This is a fork of [Clivern/Lynx](https://github.com/Clivern/Lynx) with significant additions: SSO (OIDC + SAML), SCIM 2.0 provisioning, OIDC token authentication for CI/CD pipelines, audit logging, multi-team project membership, and a full frontend rewrite from Vue.js to Phoenix LiveView with Tailwind CSS.

### What Lynx does

Lynx replaces the need for S3 + DynamoDB or Terraform Cloud for state management. You point your Terraform `backend "http"` block at Lynx, and it handles state storage, locking, and versioning in PostgreSQL. No object storage required.

The admin UI lets you organize work into teams, projects, and environments. Each environment gets its own state endpoint with credentials. You can lock environments, view state versions, roll back, and take snapshots.

### What's different in this fork

**SSO and SCIM** — Lynx supports OIDC and SAML 2.0 login with JIT user provisioning. SCIM 2.0 lets your IdP (Okta, Azure AD, etc.) automatically sync users and groups into Lynx teams. All configuration lives in the Settings page or environment variables.

**OIDC token auth for CI/CD** — GitHub Actions, GitLab CI, and other OIDC-capable runners can authenticate to Terraform backends using their native tokens instead of static secrets. You configure providers and per-environment claim-based access rules through the UI.

**Audit logging** — Every significant action (create, update, delete, lock, unlock, state push) is logged with who did it and when. The audit log page has filtering by action type and resource type.

**Multi-team projects** — Projects can belong to multiple teams, so you can share infrastructure across organizational boundaries without duplicating configuration.

**Phoenix LiveView frontend** — The original Vue.js + jQuery + Bootstrap frontend has been replaced with server-rendered Phoenix LiveView and Tailwind CSS. No CDN dependencies, no flash of unstyled content, and the UI stays in sync with the server automatically.

### Quick start

You need Docker and docker-compose. Lynx requires PostgreSQL — no object storage needed.

Run Lynx on port 4000:

```bash
wget https://raw.githubusercontent.com/Muon-Space/Lynx/main/docker-compose.yml \
    -O docker-compose.yml

docker-compose up -d
```

Open `http://localhost:4000` and follow the install wizard to create your admin account.

To run behind nginx on port 80:

```bash
wget https://raw.githubusercontent.com/Muon-Space/Lynx/main/docker-compose-nginx.yml \
    -O docker-compose.yml
wget https://raw.githubusercontent.com/Muon-Space/Lynx/main/nginx.conf \
    -O nginx.conf

docker-compose up -d
```

For Kubernetes, there's a Helm chart:

```bash
helm install lynx oci://ghcr.io/muon-space/charts/lynx
```

### Connecting Terraform

Once you've created a team, project, and environment in the UI, grab the backend configuration from the environment's "View" button:

```hcl
terraform {
  backend "http" {
    address        = "https://lynx.example.com/client/my-team/my-project/prod/state"
    lock_address   = "https://lynx.example.com/client/my-team/my-project/prod/lock"
    unlock_address = "https://lynx.example.com/client/my-team/my-project/prod/unlock"
    lock_method    = "POST"
    unlock_method  = "POST"
    username       = "env-username"
    password       = "env-secret"
  }
}
```

For OIDC token auth (e.g., from GitHub Actions), set the username to your OIDC provider name and the password to the JWT token.

### Development

Prerequisites: Elixir 1.19+, Erlang/OTP 28+, PostgreSQL.

```bash
make deps       # fetch dependencies
make migrate    # create and migrate database
make run        # start dev server on port 4000
make test       # run tests
make build      # compile with warnings-as-errors
make fmt        # format code
```

### API

Lynx exposes a RESTful JSON API for programmatic management of users, teams, projects, environments, and snapshots. All endpoints require a Bearer token (user API key) in the `Authorization` header.

The SCIM 2.0 API at `/scim/v2/` supports Users and Groups with full CRUD, filtering, and PATCH operations for IdP integration.

### License

© 2023 [Clivern](https://github.com/Clivern). Released under the [MIT License](https://opensource.org/licenses/mit-license.php).

This fork is maintained by [Muon Space](https://github.com/Muon-Space).
