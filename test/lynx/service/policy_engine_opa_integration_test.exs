defmodule Lynx.Service.PolicyEngine.OPAIntegrationTest do
  @moduledoc """
  End-to-end test against a real OPA daemon (issue #38).

  Tagged `:opa` so it doesn't run in the default suite — needs `opa` on
  PATH and a daemon listening at `OPA_URL` (default localhost:8181).
  CI's separate `opa` job installs the binary and starts it before
  invoking `make ci_opa`. Locally: `brew install opa` then
  `opa run --server` in another terminal, then `make ci_opa`.

  The test pushes a Rego module via OPA's `PUT /v1/policies/<id>` rather
  than waiting for the bundle-poll cycle — same wire format, just bypasses
  the 5–10s polling window so the test stays fast.
  """
  use ExUnit.Case, async: false

  @moduletag :opa

  alias Lynx.Service.OPABundle
  alias Lynx.Service.PolicyEngine.OPA, as: EngineOPA

  setup_all do
    # Make sure the engine config points at the right OPA. A real CI job
    # exports OPA_URL; locally the default localhost:8181 works.
    Application.put_env(
      :lynx,
      :opa_url,
      System.get_env("OPA_URL") || "http://localhost:8181"
    )

    :ok
  end

  describe "OPA HTTP wire format" do
    test "passing policy returns {:ok, []}" do
      uuid = Ecto.UUID.generate()
      suffix = OPABundle.package_suffix(uuid)

      put_policy!(suffix, """
      package lynx.policy_#{suffix}

      deny[msg] {
        false
        msg := "never"
      }
      """)

      assert {:ok, []} = EngineOPA.eval_deny(uuid, %{"resource_changes" => []})
    end

    test "failing policy returns the deny messages" do
      uuid = Ecto.UUID.generate()
      suffix = OPABundle.package_suffix(uuid)

      put_policy!(suffix, """
      package lynx.policy_#{suffix}

      deny[msg] {
        rc := input.resource_changes[_]
        rc.type == "aws_s3_bucket"
        rc.change.after.acl == "public-read"
        msg := sprintf("S3 bucket %s is public", [rc.address])
      }
      """)

      input = %{
        "resource_changes" => [
          %{
            "address" => "aws_s3_bucket.foo",
            "type" => "aws_s3_bucket",
            "change" => %{"after" => %{"acl" => "public-read"}}
          }
        ]
      }

      assert {:ok, ["S3 bucket aws_s3_bucket.foo is public"]} = EngineOPA.eval_deny(uuid, input)
    end

    test "unknown policy returns {:ok, []} (OPA reports the rule as undefined)" do
      assert {:ok, []} = EngineOPA.eval_deny(Ecto.UUID.generate(), %{})
    end
  end

  defp put_policy!(suffix, rego) do
    base = Application.fetch_env!(:lynx, :opa_url)
    url = "#{base}/v1/policies/lynx_test_#{suffix}"
    {:ok, %{status: 200}} = Req.put(url, body: rego, headers: [{"content-type", "text/plain"}])
  end
end
