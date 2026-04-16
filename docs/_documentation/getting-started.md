---
layout: documentation-single
title: Getting Started
description: A walkthrough of creating your first project and environment in Lynx.
keywords: terraform-backend, lynx, terraform
comments: false
order: 2
hero:
    title: Getting Started
    text: A walkthrough of creating your first project and environment in Lynx.
---

## Getting Started

After installing Lynx and completing the setup wizard, you'll have an admin account and can log in to the dashboard.

The basic workflow is: create a team, create a project under that team, then create environments within the project. Each environment gets its own Terraform backend URL and credentials.

### Create a team

Go to the Teams page and click "Add Team." Give it a name and slug (the slug is used in backend URLs), and add members. Teams control who can access which projects.

### Create a project

Go to Projects and click "Add Project." Assign it to one or more teams. The project slug becomes part of the backend URL.

### Create an environment

Click into your project and add an environment (e.g. "production", "staging"). Lynx generates a username and secret for Terraform authentication. You can customize these or regenerate them.

### Get the backend configuration

Click the "View" button on your environment to see the Terraform backend configuration block. Copy it into your Terraform code. See the [Usage guide]({{ site.baseurl }}/documentation/usage/) for details on configuring credentials.

### SSO and SCIM (optional)

If you want to integrate with your identity provider, go to Settings. You can configure OIDC or SAML login, enable SCIM for automated user/group provisioning, and set up OIDC token authentication for CI/CD pipelines. All of this is optional — Lynx works fine with local username/password auth.
