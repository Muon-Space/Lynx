defmodule LynxWeb.ApiSpec do
  @moduledoc """
  OpenAPI 3.0 spec for Lynx's `/api/v1/*` REST surface.

  The spec is **generated from the controllers** — every action is annotated
  with `@operation` (via `OpenApiSpex.ControllerSpecs`) and this module
  composes them into a single document.

  Two consumers:

    * `GET /api/v1/openapi.json` — served live by `LynxWeb.OpenAPIController`
    * `mix lynx.openapi.dump` — writes the YAML form to `api.yml` at the repo
      root. CI runs the task and `git diff --exit-code` to fail on drift, so
      `api.yml` is always in sync with the controllers.
  """

  alias LynxWeb.{Endpoint, Router}

  alias OpenApiSpex.{
    Components,
    Info,
    OpenApi,
    Paths,
    SecurityScheme,
    Server
  }

  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      servers: [Server.from_endpoint(Endpoint)],
      info: %Info{
        title: "Lynx",
        description: """
        Lynx is a self-hosted Terraform backend. The `/api/v1/*` REST API
        manages every resource (users, teams, projects, environments,
        snapshots, OIDC providers, audit log, settings).

        All endpoints require the `x-api-key` header — find your key on
        `/admin/profile`.
        """,
        version: lynx_version(),
        contact: %OpenApiSpex.Contact{
          name: "Muon Space",
          url: "https://github.com/Muon-Space/Lynx"
        },
        license: %OpenApiSpex.License{
          name: "MIT",
          url: "https://github.com/Muon-Space/Lynx/blob/main/LICENSE"
        }
      },
      paths: Paths.from_router(Router),
      components: %Components{
        securitySchemes: %{
          "api_key" => %SecurityScheme{
            type: "apiKey",
            in: "header",
            name: "x-api-key",
            description: "Per-user API key from `/admin/profile`"
          }
        }
      },
      security: [%{"api_key" => []}]
    }
    |> OpenApiSpex.resolve_schema_modules()
  end

  defp lynx_version do
    Application.spec(:lynx, :vsn) |> to_string()
  end
end
