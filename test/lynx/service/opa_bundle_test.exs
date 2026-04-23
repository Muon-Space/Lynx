defmodule Lynx.Service.OPABundleTest do
  @moduledoc """
  Tarball assembly + ETag for OPA bundle endpoint (issue #38).
  """
  use LynxWeb.LiveCase, async: false

  alias Lynx.Context.PolicyContext
  alias Lynx.Service.OPABundle

  setup do
    mark_installed()
    ws = create_workspace()
    project = create_project(%{workspace_id: ws.id})

    # Each test starts with no policies → ensure persistent_term cache
    # for a freshly-empty bundle isn't shared from a prior test.
    :persistent_term.erase({OPABundle, :body, OPABundle.current_etag()})

    {:ok, project: project}
  end

  describe "build/0" do
    test "empty policy set produces a valid tar.gz with just the manifest" do
      {etag, body} = OPABundle.build()
      assert etag == "empty"

      assert {:ok, files} = extract(body)
      assert {~c".manifest", manifest} = Enum.find(files, fn {n, _} -> n == ~c".manifest" end)
      assert Jason.decode!(manifest) == %{"roots" => ["lynx"]}
    end

    test "includes one rego file per enabled policy", %{project: project} do
      {:ok, p1} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{
            name: "a",
            project_id: project.id,
            rego_source: "package main\n\ndeny[\"x\"]"
          })
        )

      {:ok, p2} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{
            name: "b",
            project_id: project.id,
            rego_source: "package main\n\ndeny[\"y\"]"
          })
        )

      :persistent_term.erase({OPABundle, :body, OPABundle.current_etag()})

      {_etag, body} = OPABundle.build()
      {:ok, files} = extract(body)

      paths = Enum.map(files, fn {n, _} -> List.to_string(n) end)
      assert "lynx/policy_#{OPABundle.package_suffix(p1.uuid)}/policy.rego" in paths
      assert "lynx/policy_#{OPABundle.package_suffix(p2.uuid)}/policy.rego" in paths
    end

    test "skips disabled policies", %{project: project} do
      {:ok, _} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{
            name: "off",
            project_id: project.id,
            enabled: false,
            rego_source: "package main\n\ndeny[\"x\"]"
          })
        )

      :persistent_term.erase({OPABundle, :body, OPABundle.current_etag()})

      {_etag, body} = OPABundle.build()
      {:ok, files} = extract(body)
      assert files |> Enum.map(&elem(&1, 0)) == [~c".manifest"]
    end

    test "rewrites the user's package line to lynx.policy_<uuid>", %{project: project} do
      {:ok, p} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{
            name: "rew",
            project_id: project.id,
            rego_source: "package authors_choice\n\ndeny[msg] { msg := \"x\" }"
          })
        )

      :persistent_term.erase({OPABundle, :body, OPABundle.current_etag()})

      {_etag, body} = OPABundle.build()
      {:ok, files} = extract(body)

      {_path, rego} =
        Enum.find(files, fn {n, _} ->
          List.to_string(n) =~ OPABundle.package_suffix(p.uuid)
        end)

      assert rego =~ "package lynx.policy_#{OPABundle.package_suffix(p.uuid)}"
      refute rego =~ "package authors_choice"
      assert rego =~ "deny[msg]"
    end

    test "ETag is stable across calls when no policy changes", %{project: project} do
      {:ok, _} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{
            name: "stable",
            project_id: project.id,
            rego_source: "package x"
          })
        )

      e1 = OPABundle.current_etag()
      e2 = OPABundle.current_etag()
      assert e1 == e2
      assert e1 != "empty"
    end
  end

  defp extract(gzipped) do
    raw = :zlib.gunzip(gzipped)
    :erl_tar.extract({:binary, raw}, [:memory])
  end
end
