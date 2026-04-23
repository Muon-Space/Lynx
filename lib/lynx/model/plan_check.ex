defmodule Lynx.Model.PlanCheck do
  @moduledoc """
  Recorded outcome of a `POST /tf/.../plan` evaluation. The apply gate
  consumes this row to authorize a subsequent state-write.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @outcomes ~w(passed failed errored)

  schema "plan_checks" do
    field :uuid, Ecto.UUID
    field :environment_id, :id
    field :sub_path, :string, default: ""

    field :outcome, :string
    field :violations, :string, default: "[]"
    field :plan_json, :string

    field :actor_signature, :string
    field :actor_name, :string
    field :actor_type, :string

    field :consumed_at, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(plan_check, attrs) do
    plan_check
    |> cast(attrs, [
      :uuid,
      :environment_id,
      :sub_path,
      :outcome,
      :violations,
      :plan_json,
      :actor_signature,
      :actor_name,
      :actor_type,
      :consumed_at
    ])
    |> validate_required([
      :uuid,
      :environment_id,
      :outcome,
      :plan_json,
      :actor_signature,
      :actor_type
    ])
    |> validate_inclusion(:outcome, @outcomes)
  end

  @doc "Set of valid outcome strings — useful for tests + UI rendering."
  def outcomes, do: @outcomes
end
