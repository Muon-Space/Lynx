---
layout: homepage
title: Lynx - A Fast, Secure and Reliable Terraform Backend
description: Lynx is a remote Terraform backend built in Elixir with Phoenix LiveView. It stores state over HTTP, handles locking, and gives your team a clean admin UI.
keywords: terraform-backend, lynx, terraform

hero:
  title: A Fast, Secure and Reliable Terraform Backend
  text: Lynx is a remote Terraform backend built in Elixir with Phoenix LiveView. It stores your Terraform state over HTTP, handles locking, and gives your team a clean admin UI to manage projects, environments, and access control.
  background_image: https://images.unsplash.com/photo-1660292579530-8f55517c10d5
  buttons:
    - label: Github
      url: https://github.com/Muon-Space/Lynx
      external_url: true
      style: bordered
      icon: github
    - label: Support
      url: https://github.com/Muon-Space/Lynx/issues
      external_url: true
      style: bordered
      icon: edit

  download_link:
    label: Latest Release
    url: https://github.com/Muon-Space/Lynx/releases

features:
  rows:
    - title: Features
      description:
      grid:
        - title: Simplified Setup
          description: Run with Docker or Helm. Only needs PostgreSQL, no object storage.
          icon: database

        - title: Team Collaboration
          description: Organize users into teams with role-based access. Projects can belong to multiple teams.
          icon: server

        - title: SSO and SCIM
          description: OIDC and SAML 2.0 login with JIT provisioning. SCIM 2.0 for automated user and group sync from your IdP.
          icon: user

        - title: OIDC Token Auth
          description: CI/CD systems like GitHub Actions authenticate with native OIDC tokens. No static secrets needed.
          icon: lock

        - title: Environment Management
          description: Multiple environments per project, each with its own state endpoint, credentials, and lock controls.
          icon: square

        - title: State Versioning
          description: Every state push is versioned. Roll back to any previous version from the UI.
          icon: git-branch

        - title: Audit Logging
          description: Every action is tracked with who, what, and when. Filter by action type and resource.
          icon: activity

        - title: Terraform Locking
          description: State locking prevents concurrent operations. Lock and unlock environments directly from the admin UI.
          icon: cpu

        - title: Snapshots
          description: Point-in-time backups of project or environment state with one-click restore.
          icon: tag

        - title: RESTful API
          description: Full JSON API for programmatic management of users, teams, projects, environments, and snapshots.
          icon: code

        - title: Helm Chart
          description: Deploy to Kubernetes with the official Helm chart from GHCR.
          icon: terminal

        - title: Phoenix LiveView UI
          description: Server-rendered admin interface built with Phoenix LiveView and Tailwind CSS. No JavaScript framework dependencies.
          icon: cast

  footer:
    title:
    description:
    buttons:
---
