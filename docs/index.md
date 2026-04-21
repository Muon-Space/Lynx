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

        - title: Workspace Hierarchy
          description: Organize state by Workspace → Project → Environment → Unit. One Lynx instance can serve every repo and every team.
          icon: layers

        - title: Role-Based Access Control
          description: Planner, Applier, and Admin roles let you separate "can run plan" from "can apply." Custom roles supported.
          icon: shield

        - title: Team Collaboration
          description: Attach teams to projects with a role. Individual user grants on top compose with team grants — permissions union.
          icon: users

        - title: OIDC Token Auth
          description: GitHub Actions, GitLab CI, and other OIDC-capable runners authenticate with native tokens. No static secrets in CI.
          icon: lock

        - title: SSO and SCIM
          description: OIDC and SAML 2.0 login with JIT provisioning. SCIM 2.0 for automated user and group sync from your IdP.
          icon: user

        - title: Unit-Level State
          description: Terragrunt-style sub-paths get their own state files. One environment can host dozens of independently-locked units.
          icon: grid

        - title: State Versioning
          description: Every state push is versioned. Roll back to any previous version from the UI.
          icon: git-branch

        - title: Snapshots
          description: Point-in-time backups at project, environment, or unit scope. One-click restore (admin only).
          icon: tag

        - title: Terraform Locking
          description: State locking prevents concurrent operations. Force-unlock from the UI for stuck CI jobs.
          icon: cpu

        - title: Audit Logging
          description: Every action — create/update/delete, lock/unlock, state push, role grant, snapshot restore — tracked with who and when.
          icon: activity

        - title: RESTful API
          description: Full JSON API for programmatic management of users, teams, projects, environments, snapshots, OIDC providers.
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
