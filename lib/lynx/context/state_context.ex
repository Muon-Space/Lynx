# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Context.StateContext do
  @moduledoc """
  State Context Module
  """

  import Ecto.Query

  alias Lynx.Repo
  alias Lynx.Model.{StateMeta, State}
  alias Lynx.Context.{EnvironmentContext, ProjectContext, WorkspaceContext}
  alias Lynx.Service.Settings

  @doc """
  Get a new state
  """
  def new_state(attrs \\ %{}) do
    %{
      name: attrs.name,
      value: attrs.value,
      sub_path: Map.get(attrs, :sub_path, ""),
      environment_id: attrs.environment_id,
      uuid: Map.get(attrs, :uuid, Ecto.UUID.generate())
    }
  end

  @doc """
  Get a state meta
  """
  def new_meta(meta \\ %{}) do
    %{
      key: meta.key,
      value: meta.value,
      state_id: meta.state_id
    }
  end

  @doc """
  Create a new state
  """
  def create_state(attrs \\ %{}) do
    %State{}
    |> State.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Retrieve a state by ID
  """
  def get_state_by_id(id) do
    Repo.get(State, id)
  end

  @doc """
  Get state by UUID
  """
  def get_state_by_uuid(uuid) do
    from(
      s in State,
      where: s.uuid == ^uuid
    )
    |> Repo.one()
  end

  @doc """
  Get state by name
  """
  def get_state_by_name(name) do
    from(
      s in State,
      where: s.name == ^name
    )
    |> Repo.one()
  end

  @doc """
  Get latest state by environment id
  """
  def get_latest_state_by_environment_id(environment_id) do
    from(
      s in State,
      where: s.environment_id == ^environment_id
    )
    |> last(:id)
    |> Repo.one()
  end

  def get_latest_state_by_environment_and_path(environment_id, sub_path) do
    from(
      s in State,
      where: s.environment_id == ^environment_id,
      where: s.sub_path == ^sub_path
    )
    |> last(:id)
    |> Repo.one()
  end

  @doc """
  Get states by environment id
  """
  def get_states_by_environment_id(environment_id) do
    from(
      s in State,
      where: s.environment_id == ^environment_id
    )
    |> Repo.all()
  end

  @doc """
  Count environment states
  """
  def count_states(environment_id) do
    from(s in State,
      select: count(s.id),
      where: s.environment_id == ^environment_id
    )
    |> Repo.one()
  end

  @doc """
  Compute a semantic diff between two Terraform state versions, keyed on
  resource identity `(mode, type, name, instance.index_key)` so a
  `count`-expanded resource shows one card per instance rather than one
  whole-resource churn.

  Accepts either two `%State{}` structs, two raw JSON strings, or a mix.

  Returns:

      %{
        added:   [%{key: id_tuple, mode: ..., type: ..., name: ..., index_key: ..., attributes: %{...}}],
        changed: [%{key: ..., mode: ..., type: ..., name: ..., index_key: ..., before: %{...}, after: %{...}, attributes: [{k, before, after}]}],
        removed: [%{key: ..., mode: ..., type: ..., name: ..., index_key: ..., attributes: %{...}}]
      }

  Each `changed` entry's `:attributes` list contains only the keys that
  actually differ — not the full attribute set. Sentinel `:absent` is used
  when a key exists on one side and not the other.

  Resilient to malformed input: anything that doesn't decode to a JSON
  object gets treated as an empty state. State files prior to terraform
  0.12 (no top-level `resources` array) are also treated as empty —
  Lynx wasn't a backend for them.
  """
  @spec diff(any(), any()) :: %{added: list(), changed: list(), removed: list()}
  def diff(before, after_state) do
    before_idx = decode_resources(before)
    after_idx = decode_resources(after_state)

    before_keys = MapSet.new(Map.keys(before_idx))
    after_keys = MapSet.new(Map.keys(after_idx))

    added =
      MapSet.difference(after_keys, before_keys)
      |> Enum.sort()
      |> Enum.map(fn key -> resource_entry(key, after_idx[key], :added) end)

    removed =
      MapSet.difference(before_keys, after_keys)
      |> Enum.sort()
      |> Enum.map(fn key -> resource_entry(key, before_idx[key], :removed) end)

    changed =
      MapSet.intersection(before_keys, after_keys)
      |> Enum.sort()
      |> Enum.flat_map(fn key ->
        b = before_idx[key]
        a = after_idx[key]

        case attribute_diff(b["attributes"], a["attributes"]) do
          [] -> []
          attrs -> [resource_entry(key, a, :changed, before: b, after: a, attributes: attrs)]
        end
      end)

    %{added: added, changed: changed, removed: removed}
  end

  # Returns `%{key_tuple => instance_payload}` for every resource instance.
  defp decode_resources(%State{value: value}), do: decode_resources(value)
  defp decode_resources(nil), do: %{}
  defp decode_resources(""), do: %{}

  defp decode_resources(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"resources" => resources}} when is_list(resources) ->
        for %{"mode" => mode, "type" => type, "name" => name, "instances" => instances} <-
              resources,
            instance <- List.wrap(instances),
            into: %{} do
          index_key = Map.get(instance, "index_key")
          payload = Map.put(instance, "_meta", %{mode: mode, type: type, name: name})
          {{mode, type, name, index_key}, payload}
        end

      _ ->
        %{}
    end
  end

  defp decode_resources(_), do: %{}

  defp resource_entry(key, payload, status, extras \\ []) do
    {mode, type, name, index_key} = key

    base = %{
      key: key,
      status: status,
      mode: mode,
      type: type,
      name: name,
      index_key: index_key,
      attributes: Map.get(payload || %{}, "attributes", %{})
    }

    Enum.into(extras, base)
  end

  # Per-attribute diff: returns `[{key, before, after}]` for keys that differ.
  # `:absent` sentinel marks "key not present on this side". Nested maps are
  # compared as a whole — Terraform attributes are usually flat enough that
  # showing the full sub-map on either side is more readable than recursing.
  defp attribute_diff(nil, nil), do: []
  defp attribute_diff(nil, after_attrs), do: attribute_diff(%{}, after_attrs)
  defp attribute_diff(before_attrs, nil), do: attribute_diff(before_attrs, %{})

  defp attribute_diff(before_attrs, after_attrs)
       when is_map(before_attrs) and is_map(after_attrs) do
    keys = MapSet.union(MapSet.new(Map.keys(before_attrs)), MapSet.new(Map.keys(after_attrs)))

    keys
    |> Enum.sort()
    |> Enum.flat_map(fn k ->
      b = Map.get(before_attrs, k, :absent)
      a = Map.get(after_attrs, k, :absent)
      if b == a, do: [], else: [{k, b, a}]
    end)
  end

  defp attribute_diff(_, _), do: []

  def count_states_by_path(environment_id, sub_path) do
    from(s in State,
      select: count(s.id),
      where: s.environment_id == ^environment_id,
      where: s.sub_path == ^sub_path
    )
    |> Repo.one()
  end

  def trim_old_states(environment_id, sub_path, keep) do
    ids_to_keep =
      from(s in State,
        select: s.id,
        where: s.environment_id == ^environment_id,
        where: s.sub_path == ^sub_path,
        order_by: [desc: s.id],
        limit: ^keep
      )
      |> Repo.all()

    case ids_to_keep do
      [] ->
        0

      _ ->
        {count, _} =
          from(s in State,
            where: s.environment_id == ^environment_id,
            where: s.sub_path == ^sub_path,
            where: s.id not in ^ids_to_keep
          )
          |> Repo.delete_all()

        count
    end
  end

  def list_sub_paths(environment_id) do
    from(s in State,
      select: %{
        sub_path: s.sub_path,
        count: count(s.id),
        latest: max(s.inserted_at)
      },
      where: s.environment_id == ^environment_id,
      group_by: s.sub_path,
      order_by: [asc: s.sub_path]
    )
    |> Repo.all()
  end

  @doc """
  Update a state
  """
  def update_state(state, attrs) do
    state
    |> State.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a state
  """
  def delete_state(state) do
    Repo.delete(state)
  end

  @doc """
  Retrieve states
  """
  def get_states(offset, limit) do
    from(s in State,
      limit: ^limit,
      offset: ^offset
    )
    |> Repo.all()
  end

  @doc """
  Create a new state meta attribute
  """
  def create_state_meta(attrs \\ %{}) do
    %StateMeta{}
    |> StateMeta.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Retrieve a state meta by id
  """
  def get_state_meta_by_id(id) do
    Repo.get(StateMeta, id)
  end

  @doc """
  Update a state meta
  """
  def update_state_meta(state_meta, attrs) do
    state_meta
    |> StateMeta.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a state meta
  """
  def delete_state_meta(state_meta) do
    state_meta
    |> Repo.delete()
  end

  @doc """
  Get state meta by state id and key
  """
  def get_state_meta_by_id_key(state_id, meta_key) do
    from(
      s in StateMeta,
      where: s.state_id == ^state_id,
      where: s.key == ^meta_key
    )
    |> Repo.one()
  end

  @doc """
  Get state metas
  """
  def get_state_metas(state_id) do
    from(
      s in StateMeta,
      where: s.state_id == ^state_id
    )
    |> Repo.all()
  end

  # -- Workspace/project/env-aware orchestration --

  def get_latest_state(params \\ %{}) do
    case resolve_env(params) do
      {:error, msg} ->
        {:not_found, msg}

      {:ok, env} ->
        sub_path = params[:sub_path] || ""

        case get_latest_state_by_environment_and_path(env.id, sub_path) do
          nil -> {:no_state, ""}
          state -> {:state_found, state}
        end
    end
  end

  def add_state(params \\ %{}) do
    case resolve_env(params) do
      {:error, msg} ->
        {:not_found, msg}

      {:ok, env} ->
        state =
          new_state(%{
            environment_id: env.id,
            name: params[:name],
            value: params[:value],
            sub_path: params[:sub_path] || ""
          })

        case create_state(state) do
          {:ok, _} ->
            trim_if_configured(env.id, params[:sub_path] || "")
            {:success, ""}

          {:error, changeset} ->
            messages =
              changeset.errors
              |> Enum.map(fn {field, {message, _options}} -> "#{field}: #{message}" end)

            {:error, Enum.at(messages, 0)}
        end
    end
  end

  def get_latest_state_by_env_uuid(uuid) do
    case EnvironmentContext.get_env_by_uuid(uuid) do
      nil -> nil
      env -> get_latest_state_by_environment_id(env.id)
    end
  end

  defp resolve_env(params) do
    workspace = WorkspaceContext.get_workspace_by_slug(params[:w_slug])

    project =
      if workspace do
        ProjectContext.get_project_by_slug_and_workspace(params[:p_slug], workspace.id)
      else
        nil
      end

    case project do
      nil ->
        {:error, "Project not found"}

      project ->
        case EnvironmentContext.get_env_by_slug_project(project.id, params[:e_slug]) do
          nil -> {:error, "Environment not found"}
          env -> {:ok, env}
        end
    end
  end

  defp trim_if_configured(environment_id, sub_path) do
    case Settings.get_config("state_retention_count", "0") do
      "0" ->
        :ok

      "" ->
        :ok

      count_str ->
        case Integer.parse(count_str) do
          {count, _} when count > 0 -> trim_old_states(environment_id, sub_path, count)
          _ -> :ok
        end
    end
  end
end
