defmodule EvilEngineWeb.Graphql.Phases.BlockIntrospection do
  @moduledoc """
  Absinthe validation phase that rejects `__schema` and `__type` introspection
  root fields when introspection is disabled.

  Enabled by `Application.get_env(:api_web, :graphql_introspection_disabled, false)`,
  which is wired to the `EVIL_GRAPHQL_INTROSPECTION_DISABLED` environment
  variable. Defaults to `false` so development and test environments retain
  full introspection.

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
    Enum.find_value(blueprint.operations, fn op ->
      Enum.find(op.selections, fn
        %Blueprint.Document.Field{name: name} when name in @blocked_fields -> true
        _ -> false
      end)
    end)
  end
end
