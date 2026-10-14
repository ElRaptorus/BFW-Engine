defmodule BfwEngineWeb.Graphql.Phases.BlockIntrospection do
  @moduledoc """
  Absinthe validation phase that rejects `__schema` and `__type` introspection
  root fields when introspection is disabled.

  Enabled by `Application.get_env(:api_web, :graphql_introspection_disabled, false)`,
  which is wired to the `BFE_GRAPHQL_INTROSPECTION_DISABLED` environment
  variable. Defaults to `false` so development and test environments retain
  full introspection.

  Root selections are searched through inline fragments and named fragment
  spreads (resolved via `blueprint.fragments`, cycle-guarded), so wrapping
  `__schema` / `__type` in a fragment does not bypass the block.

  `__typename` is **not** blocked: it is commonly required by GraphQL
  client libraries for union / interface type discrimination and is not
  a schema-enumeration vector.
  """

  use Absinthe.Phase

  alias Absinthe.Blueprint
  alias Absinthe.Phase.Error

  @blocked_fields ~w(__schema __type)

  @impl Absinthe.Phase
  def run(%Blueprint{} = blueprint, options) do
    if Application.get_env(:api_web, :graphql_introspection_disabled, false) do
      maybe_reject_introspection(blueprint, options)
    else
      {:ok, blueprint}
    end
  end

  defp maybe_reject_introspection(blueprint, options) do
    case find_introspection_field(blueprint) do
      nil ->
        {:ok, blueprint}

      _field ->
        reject_with_error(blueprint, options)
    end
  end

  defp reject_with_error(blueprint, options) do
    error = %Error{
      phase: __MODULE__,
      message: "Introspection is disabled."
    }

    blueprint = update_in(blueprint.execution.validation_errors, &[error | &1])

    case Map.new(options) do
      %{jump_phases: true, result_phase: result_phase} ->
        {:jump, blueprint, result_phase}

      _ ->
        {:error, %{blueprint | errors: [error | blueprint.errors]}}
    end
  end

  defp find_introspection_field(blueprint) do
    Enum.find_value(blueprint.operations, fn operation ->
      find_in_selections(operation.selections, blueprint.fragments, %{})
    end)
  end

  defp find_in_selections(selections, fragments, visited_names) do
    Enum.find_value(selections, fn selection ->
      find_in_selection(selection, fragments, visited_names)
    end)
  end

  defp find_in_selection(%Blueprint.Document.Field{name: name}, _fragments, _visited_names)
       when name in @blocked_fields,
       do: true

  defp find_in_selection(
         %Blueprint.Document.Fragment.Inline{selections: children},
         fragments,
         visited_names
       ),
       do: find_in_selections(children, fragments, visited_names)

  defp find_in_selection(
         %Blueprint.Document.Fragment.Spread{name: name},
         fragments,
         visited_names
       ) do
    with false <- Map.has_key?(visited_names, name),
         %{selections: children} <- Enum.find(fragments, &(&1.name == name)) do
      find_in_selections(children, fragments, Map.put(visited_names, name, true))
    else
      _already_visited_or_unknown -> nil
    end
  end

  defp find_in_selection(_other_selection, _fragments, _visited_names), do: nil
end
