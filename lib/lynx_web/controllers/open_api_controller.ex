defmodule LynxWeb.OpenAPIController do
  @moduledoc """
  Serves the generated OpenAPI 3.0 spec.

  The spec itself is built from `@operation` annotations on every REST
  controller and assembled by `LynxWeb.ApiSpec`. There's no hand-written
  YAML to drift — the snapshot at the repo root (`api.yml`) is regenerated
  by `mix lynx.openapi.dump` and CI fails on any diff.

  No auth gate: the spec is intentionally public so a deployed instance
  documents itself.

  Three formats:

    * `GET /api/v1/openapi.json` — JSON, the canonical machine-readable form
    * `GET /api/v1/openapi.yml`  — YAML, hand-readable in browsers
  """
  use LynxWeb, :controller

  alias LynxWeb.ApiSpec

  def spec_json(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(ApiSpec.spec()))
  end

  def spec_yaml(conn, _params) do
    yaml = ApiSpec.spec() |> spec_to_yaml()

    conn
    |> put_resp_content_type("application/yaml")
    |> send_resp(200, yaml)
  end

  @doc false
  def spec_to_yaml(spec) do
    spec
    |> Jason.encode!()
    |> Jason.decode!()
    |> Ymlr.document!()
  end
end
