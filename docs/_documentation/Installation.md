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

Lynx is a remote Terraform backend that stores state over HTTP with locking, versioning, and rollback. It replaces the need for S3 + DynamoDB or Terraform Cloud for state management. All it needs is PostgreSQL — no object storage required.

The admin UI lets you organize work into teams, projects, and environments. Each environment gets its own state endpoint with credentials. You can lock environments, view state versions, take snapshots, and configure OIDC token-based access for CI/CD.

This is a fork of [Clivern/Lynx](https://github.com/Clivern/Lynx) with SSO (OIDC + SAML), SCIM 2.0 provisioning, OIDC token authentication for CI/CD pipelines, audit logging, multi-team project membership, and a frontend rewrite to Phoenix LiveView with Tailwind CSS.


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
