# Schemas referenced by `@operation` annotations across REST controllers.
# All schemas live in this single file so the OpenAPI surface is auditable
# in one place; each is still its own module so `open_api_spex` can resolve
# `$ref`s against it.
#
# Naming convention:
#
#   * `Resource`         — the wire shape returned by show/create/update endpoints
#   * `ResourceList`     — wraps a list + `_metadata` pagination block
#   * `ResourceCreate`   — request body for POST/PUT
#   * `Error`            — `{errorMessage}` shape
#   * `Success`          — `{successMessage}` shape
#
# When adding new endpoints, add the schema here first and reference it from
# the controller's `operation :name, responses: [...]` block.

defmodule LynxWeb.Schemas.ListMetadata do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ListMetadata",
    type: :object,
    properties: %{
      limit: %Schema{type: :integer},
      offset: %Schema{type: :integer},
      totalCount: %Schema{type: :integer}
    }
  })
end

defmodule LynxWeb.Schemas.Error do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Error",
    description: "Error response",
    type: :object,
    properties: %{
      errorMessage: %Schema{type: :string}
    }
  })
end

defmodule LynxWeb.Schemas.Success do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Success",
    description: "Generic success response",
    type: :object,
    properties: %{
      successMessage: %Schema{type: :string}
    }
  })
end

# -- User --

defmodule LynxWeb.Schemas.User do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "User",
    type: :object,
    properties: %{
      id: %Schema{type: :string, description: "UUID"},
      email: %Schema{type: :string, format: :email},
      name: %Schema{type: :string},
      role: %Schema{type: :string, enum: ["super", "regular"]},
      isActive: %Schema{type: :boolean},
      authProvider: %Schema{type: :string, enum: ["local", "oidc", "saml", "scim"]},
      createdAt: %Schema{type: :string, format: :"date-time"},
      updatedAt: %Schema{type: :string, format: :"date-time"}
    }
  })
end

defmodule LynxWeb.Schemas.UserList do
  alias OpenApiSpex.Schema
  alias LynxWeb.Schemas.{ListMetadata, User}
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "UserList",
    type: :object,
    properties: %{
      users: %Schema{type: :array, items: User},
      _metadata: ListMetadata
    }
  })
end

defmodule LynxWeb.Schemas.UserCreate do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "UserCreate",
    type: :object,
    required: [:name, :email, :role],
    properties: %{
      name: %Schema{type: :string},
      email: %Schema{type: :string, format: :email},
      role: %Schema{type: :string, enum: ["super", "regular"]},
      password: %Schema{type: :string}
    }
  })
end

# -- Team --

defmodule LynxWeb.Schemas.Team do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Team",
    type: :object,
    properties: %{
      id: %Schema{type: :string, description: "UUID"},
      name: %Schema{type: :string},
      slug: %Schema{type: :string},
      description: %Schema{type: :string},
      usersCount: %Schema{type: :integer},
      projectsCount: %Schema{type: :integer},
      members: %Schema{type: :array, items: %Schema{type: :string, description: "User UUID"}},
      createdAt: %Schema{type: :string, format: :"date-time"},
      updatedAt: %Schema{type: :string, format: :"date-time"}
    }
  })
end

defmodule LynxWeb.Schemas.TeamList do
  alias OpenApiSpex.Schema
  alias LynxWeb.Schemas.{ListMetadata, Team}
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "TeamList",
    type: :object,
    properties: %{
      teams: %Schema{type: :array, items: Team},
      _metadata: ListMetadata
    }
  })
end

defmodule LynxWeb.Schemas.TeamCreate do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "TeamCreate",
    type: :object,
    required: [:name, :slug, :description],
    properties: %{
      name: %Schema{type: :string},
      slug: %Schema{type: :string},
      description: %Schema{type: :string},
      members: %Schema{
        type: :array,
        items: %Schema{type: :string, description: "User UUID"}
      }
    }
  })
end

# -- Project --

defmodule LynxWeb.Schemas.ProjectTeamRef do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ProjectTeamRef",
    type: :object,
    properties: %{
      id: %Schema{type: :string},
      name: %Schema{type: :string},
      slug: %Schema{type: :string}
    }
  })
end

defmodule LynxWeb.Schemas.Project do
  alias OpenApiSpex.Schema
  alias LynxWeb.Schemas.ProjectTeamRef
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Project",
    type: :object,
    properties: %{
      id: %Schema{type: :string, description: "UUID"},
      name: %Schema{type: :string},
      slug: %Schema{type: :string},
      description: %Schema{type: :string},
      teams: %Schema{type: :array, items: ProjectTeamRef},
      team: %Schema{
        oneOf: [ProjectTeamRef, %Schema{type: :null}],
        description: "First team (backwards compat)"
      },
      envCount: %Schema{type: :integer},
      createdAt: %Schema{type: :string, format: :"date-time"},
      updatedAt: %Schema{type: :string, format: :"date-time"}
    }
  })
end

defmodule LynxWeb.Schemas.ProjectList do
  alias OpenApiSpex.Schema
  alias LynxWeb.Schemas.{ListMetadata, Project}
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ProjectList",
    type: :object,
    properties: %{
      projects: %Schema{type: :array, items: Project},
      _metadata: ListMetadata
    }
  })
end

defmodule LynxWeb.Schemas.ProjectCreate do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ProjectCreate",
    type: :object,
    required: [:name, :slug, :description],
    properties: %{
      name: %Schema{type: :string},
      slug: %Schema{type: :string},
      description: %Schema{type: :string},
      team_id: %Schema{type: :string, description: "Single team UUID (legacy)"},
      team_ids: %Schema{
        type: :array,
        items: %Schema{type: :string, description: "Team UUID"}
      }
    }
  })
end

# -- Environment --

defmodule LynxWeb.Schemas.EnvironmentProjectRef do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "EnvironmentProjectRef",
    type: :object,
    properties: %{
      id: %Schema{type: :string, description: "Project UUID"}
    }
  })
end

defmodule LynxWeb.Schemas.Environment do
  alias OpenApiSpex.Schema
  alias LynxWeb.Schemas.EnvironmentProjectRef
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Environment",
    type: :object,
    properties: %{
      id: %Schema{type: :string, description: "UUID"},
      name: %Schema{type: :string},
      slug: %Schema{type: :string},
      username: %Schema{type: :string},
      secret: %Schema{type: :string, description: "Static credential for legacy auth"},
      isLocked: %Schema{type: :boolean},
      stateVersion: %Schema{type: :integer},
      project: EnvironmentProjectRef,
      createdAt: %Schema{type: :string, format: :"date-time"},
      updatedAt: %Schema{type: :string, format: :"date-time"}
    }
  })
end

defmodule LynxWeb.Schemas.EnvironmentList do
  alias OpenApiSpex.Schema
  alias LynxWeb.Schemas.{Environment, ListMetadata}
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "EnvironmentList",
    type: :object,
    properties: %{
      environments: %Schema{type: :array, items: Environment},
      _metadata: ListMetadata
    }
  })
end

defmodule LynxWeb.Schemas.EnvironmentCreate do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "EnvironmentCreate",
    type: :object,
    required: [:name, :slug, :username, :secret],
    properties: %{
      name: %Schema{type: :string},
      slug: %Schema{type: :string},
      username: %Schema{type: :string},
      secret: %Schema{type: :string}
    }
  })
end

# -- Snapshot --

defmodule LynxWeb.Schemas.SnapshotTeamRef do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "SnapshotTeamRef",
    type: :object,
    properties: %{
      id: %Schema{type: :string},
      name: %Schema{type: :string},
      slug: %Schema{type: :string}
    }
  })
end

defmodule LynxWeb.Schemas.Snapshot do
  alias OpenApiSpex.Schema
  alias LynxWeb.Schemas.SnapshotTeamRef
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Snapshot",
    type: :object,
    properties: %{
      id: %Schema{type: :string, description: "UUID"},
      title: %Schema{type: :string},
      description: %Schema{type: :string},
      record_type: %Schema{type: :string, enum: ["project", "environment", "unit"]},
      record_uuid: %Schema{type: :string},
      status: %Schema{type: :string, enum: ["success", "failure", "pending"]},
      team: SnapshotTeamRef,
      createdAt: %Schema{type: :string, format: :"date-time"},
      updatedAt: %Schema{type: :string, format: :"date-time"}
    }
  })
end

defmodule LynxWeb.Schemas.SnapshotList do
  alias OpenApiSpex.Schema
  alias LynxWeb.Schemas.{ListMetadata, Snapshot}
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "SnapshotList",
    type: :object,
    properties: %{
      snapshots: %Schema{type: :array, items: Snapshot},
      _metadata: ListMetadata
    }
  })
end

defmodule LynxWeb.Schemas.SnapshotCreate do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "SnapshotCreate",
    type: :object,
    required: [:title, :description, :record_type, :record_uuid, :team_id],
    properties: %{
      title: %Schema{type: :string},
      description: %Schema{type: :string},
      record_type: %Schema{type: :string, enum: ["project", "environment", "unit"]},
      record_uuid: %Schema{type: :string},
      team_id: %Schema{type: :string, description: "Team UUID"}
    }
  })
end

defmodule LynxWeb.Schemas.SnapshotUpdate do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "SnapshotUpdate",
    type: :object,
    properties: %{
      title: %Schema{type: :string},
      description: %Schema{type: :string},
      team_id: %Schema{type: :string}
    }
  })
end

# -- Task --

defmodule LynxWeb.Schemas.Task do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Task",
    type: :object,
    properties: %{
      id: %Schema{type: :string},
      status: %Schema{type: :string},
      runAt: %Schema{type: :string, format: :"date-time"},
      createdAt: %Schema{type: :string, format: :"date-time"},
      updatedAt: %Schema{type: :string, format: :"date-time"}
    }
  })
end

# -- Audit --

defmodule LynxWeb.Schemas.AuditEvent do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AuditEvent",
    type: :object,
    properties: %{
      id: %Schema{type: :integer},
      actorId: %Schema{type: :integer, nullable: true},
      actorName: %Schema{type: :string, nullable: true},
      actorType: %Schema{type: :string, enum: ["user", "system"]},
      action: %Schema{type: :string},
      resourceType: %Schema{type: :string},
      resourceId: %Schema{type: :string, nullable: true},
      resourceName: %Schema{type: :string, nullable: true},
      metadata: %Schema{type: :string, nullable: true, description: "JSON-encoded metadata"},
      createdAt: %Schema{type: :string, format: :"date-time"}
    }
  })
end

defmodule LynxWeb.Schemas.AuditEventList do
  alias OpenApiSpex.Schema
  alias LynxWeb.Schemas.{AuditEvent, ListMetadata}
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AuditEventList",
    type: :object,
    properties: %{
      events: %Schema{type: :array, items: AuditEvent},
      _metadata: ListMetadata
    }
  })
end

# -- OIDC --

defmodule LynxWeb.Schemas.OIDCProvider do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "OIDCProvider",
    type: :object,
    properties: %{
      id: %Schema{type: :string, description: "UUID"},
      name: %Schema{type: :string},
      discoveryUrl: %Schema{type: :string},
      audience: %Schema{type: :string},
      isActive: %Schema{type: :boolean},
      successMessage: %Schema{type: :string, description: "Present on create/update"},
      createdAt: %Schema{type: :string, format: :"date-time"}
    }
  })
end

defmodule LynxWeb.Schemas.OIDCProviderList do
  alias OpenApiSpex.Schema
  alias LynxWeb.Schemas.OIDCProvider
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "OIDCProviderList",
    type: :object,
    properties: %{
      providers: %Schema{type: :array, items: OIDCProvider}
    }
  })
end

defmodule LynxWeb.Schemas.OIDCProviderCreate do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "OIDCProviderCreate",
    type: :object,
    required: [:name, :discovery_url, :audience],
    properties: %{
      name: %Schema{type: :string},
      discovery_url: %Schema{type: :string},
      audience: %Schema{type: :string}
    }
  })
end

defmodule LynxWeb.Schemas.OIDCRule do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "OIDCRule",
    type: :object,
    properties: %{
      id: %Schema{type: :string, description: "UUID"},
      name: %Schema{type: :string},
      claimRules: %Schema{type: :object, additionalProperties: %Schema{type: :string}},
      providerId: %Schema{type: :integer},
      environmentId: %Schema{type: :integer},
      isActive: %Schema{type: :boolean},
      successMessage: %Schema{type: :string, description: "Present on create"},
      createdAt: %Schema{type: :string, format: :"date-time"}
    }
  })
end

defmodule LynxWeb.Schemas.OIDCRuleList do
  alias OpenApiSpex.Schema
  alias LynxWeb.Schemas.OIDCRule
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "OIDCRuleList",
    type: :object,
    properties: %{
      rules: %Schema{type: :array, items: OIDCRule}
    }
  })
end

defmodule LynxWeb.Schemas.OIDCRuleCreate do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "OIDCRuleCreate",
    type: :object,
    required: [:name, :provider_id, :environment_id],
    properties: %{
      name: %Schema{type: :string},
      provider_id: %Schema{type: :string, description: "Provider UUID"},
      environment_id: %Schema{type: :string, description: "Environment UUID"},
      role_id: %Schema{type: :integer, description: "Role granted on match. Defaults to applier."},
      claim_rules: %Schema{
        oneOf: [
          %Schema{type: :object, additionalProperties: %Schema{type: :string}},
          %Schema{type: :string, description: "Pre-encoded JSON"}
        ]
      }
    }
  })
end

# -- Profile --

defmodule LynxWeb.Schemas.ProfileUpdate do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ProfileUpdate",
    type: :object,
    properties: %{
      name: %Schema{type: :string},
      email: %Schema{type: :string, format: :email},
      password: %Schema{type: :string}
    }
  })
end

defmodule LynxWeb.Schemas.ApiKey do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ApiKey",
    type: :object,
    properties: %{
      apiKey: %Schema{type: :string}
    }
  })
end

# -- Settings --

defmodule LynxWeb.Schemas.SettingsUpdate do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "SettingsUpdate",
    type: :object,
    properties: %{
      app_name: %Schema{type: :string},
      app_url: %Schema{type: :string},
      app_email: %Schema{type: :string, format: :email}
    }
  })
end

defmodule LynxWeb.Schemas.SsoSettingsUpdate do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "SsoSettingsUpdate",
    type: :object,
    description: "SSO + auth toggles. Field set is intentionally permissive — see config docs.",
    additionalProperties: true,
    properties: %{
      auth_password_enabled: %Schema{type: :boolean},
      auth_sso_enabled: %Schema{type: :boolean},
      sso_protocol: %Schema{type: :string, enum: ["oidc", "saml"]},
      scim_enabled: %Schema{type: :boolean}
    }
  })
end

defmodule LynxWeb.Schemas.SamlCertResponse do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "SamlCertResponse",
    type: :object,
    properties: %{
      successMessage: %Schema{type: :string},
      cert_pem: %Schema{type: :string}
    }
  })
end

defmodule LynxWeb.Schemas.ScimTokenCreate do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ScimTokenCreate",
    type: :object,
    properties: %{
      description: %Schema{type: :string}
    }
  })
end

defmodule LynxWeb.Schemas.ScimTokenCreated do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ScimTokenCreated",
    description: "Returned once on creation; the raw token cannot be re-fetched later.",
    type: :object,
    properties: %{
      uuid: %Schema{type: :string},
      token: %Schema{type: :string},
      description: %Schema{type: :string}
    }
  })
end

defmodule LynxWeb.Schemas.ScimToken do
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ScimToken",
    type: :object,
    properties: %{
      id: %Schema{type: :string},
      description: %Schema{type: :string},
      createdAt: %Schema{type: :string, format: :"date-time"}
    }
  })
end

defmodule LynxWeb.Schemas.ScimTokenList do
  alias OpenApiSpex.Schema
  alias LynxWeb.Schemas.ScimToken
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ScimTokenList",
    type: :object,
    properties: %{
      tokens: %Schema{type: :array, items: ScimToken}
    }
  })
end
