defmodule Mix.Tasks.Lynx.Openapi.Dump do
  @moduledoc """
  Dump the live OpenAPI spec (built from `@operation` annotations) to
  `api.yml` at the repo root.

  Used by CI to detect drift between the controllers and the committed
  `api.yml` snapshot:

      mix lynx.openapi.dump
      git diff --exit-code api.yml

  If the diff is non-empty, the controllers changed without the spec being
  regenerated — the developer needs to run the dump locally and commit the
  resulting `api.yml`.

  Run with `--check` to fail-fast if the on-disk spec is stale (no write).
  """
  use Mix.Task

  alias LynxWeb.{ApiSpec, OpenAPIController}

  @shortdoc "Dump the OpenAPI spec to api.yml (use --check to fail on drift)"
  # `__DIR__` here is `lib/mix/tasks/`. Three levels up = repo root.
  @target Path.expand("../../../api.yml", __DIR__)

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [check: :boolean])

    Mix.Task.run("app.start")

    fresh = ApiSpec.spec() |> OpenAPIController.spec_to_yaml()

    cond do
      opts[:check] ->
        check_drift(fresh)

      true ->
        File.write!(@target, fresh)
        Mix.shell().info("Wrote OpenAPI spec to #{Path.relative_to_cwd(@target)}")
    end
  end

  defp check_drift(fresh) do
    on_disk = if File.exists?(@target), do: File.read!(@target), else: ""

    if String.trim(fresh) == String.trim(on_disk) do
      Mix.shell().info("OpenAPI spec is in sync with controllers ✓")
    else
      Mix.shell().error("""
      OpenAPI spec drift detected — `api.yml` is stale.

      Controllers have been annotated with `@operation` macros that don't
      match the committed `api.yml`. Regenerate it with:

          mix lynx.openapi.dump

      Then commit the updated `api.yml` and push.
      """)

      Mix.raise("openapi spec drift")
    end
  end
end
