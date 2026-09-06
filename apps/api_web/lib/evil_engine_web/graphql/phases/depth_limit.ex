defmodule EvilEngineWeb.Graphql.Phases.DepthLimit do
  @moduledoc """
  Absinthe validation phase that rejects documents whose maximum selection-set
  depth exceeds the configured limit.

  "Depth" is the number of nested field selections starting from the
  operation root. `{ user { friends { address { city } } } }` has depth 4.

  Fragment spreads are followed recursively (Absinthe guarantees no cycles
  by the time this phase runs). Inline fragments and spread boundaries do
  not add depth; only `Field` selections do.

  Reads `Application.get_env(:api_web, :graphql_max_depth, 16)` at
  runtime so the limit is configurable via `TDE_GRAPHQL_MAX_DEPTH` without
  recompiling. Default 16 is sized for the Process Model graph's recursive
  `SubProcessNode.flowNodes` (WP-7); the previous default of 10 was sized
  for the flat persistence graph.
  """

  use Absinthe.Phase

  alias Absinthe.Blueprint
  alias Absinthe.Phase.Error

  # `seen` is a plain map used as a visited-fragment set to guard against
  # circular spreads. We use `%{String.t() => true}` rather than `MapSet`
  # because Dialyzer's PLT entry for `MapSet` exposes the internal struct
  # representation, causing spurious `call_without_opaque` warnings on
  # `MapSet.member?`. A plain map has no such opaque-type PLT issue.

  @impl Absinthe.Phase
  def run(%Blueprint{} = blueprint, options) do
    max_depth = Application.get_env(:api_web, :graphql_max_depth, 16)
    frag_index = Map.new(blueprint.fragments, &{&1.name, &1})

    depth_exceeded? =
      Enum.any?(blueprint.operations, fn op ->
        max_selection_depth(op.selections, frag_index, %{}, 0) > max_depth
      end)

    if depth_exceeded? do
      error = %Error{
        phase: __MODULE__,
        message: "Query depth limit of #{max_depth} exceeded."
      }

      blueprint = update_in(blueprint.execution.validation_errors, &[error | &1])

      case Map.new(options) do
        %{jump_phases: true, result_phase: result_phase} ->
          {:jump, blueprint, result_phase}

        _ ->
          {:error, %{blueprint | errors: [error | blueprint.errors]}}
      end
    else
      {:ok, blueprint}
    end
  end

  # Returns the maximum field depth reachable from `selections`, where
  # `current` is the depth of the parent selection. Each Field adds 1;
  # Inline fragments and Spreads do not add depth.
  @spec max_selection_depth(list(), map(), %{optional(String.t()) => true}, non_neg_integer()) ::
          non_neg_integer()
  defp max_selection_depth([], _frags, _seen, current), do: current

  defp max_selection_depth(selections, frags, seen, current) do
    Enum.reduce(selections, current, fn sel, acc ->
      max(selection_depth(sel, frags, seen, current), acc)
    end)
  end

  @spec selection_depth(
          Blueprint.Document.selection_t(),
          map(),
          %{optional(String.t()) => true},
          non_neg_integer()
        ) :: non_neg_integer()
  defp selection_depth(%Blueprint.Document.Field{selections: children}, frags, seen, current) do
    max_selection_depth(children, frags, seen, current + 1)
  end

  defp selection_depth(
         %Blueprint.Document.Fragment.Inline{selections: children},
         frags,
         seen,
         current
       ) do
    max_selection_depth(children, frags, seen, current)
  end

  defp selection_depth(%Blueprint.Document.Fragment.Spread{name: name}, frags, seen, current) do
    if Map.has_key?(seen, name) do
      current
    else
      case Map.get(frags, name) do
        nil ->
          current

        %{selections: children} ->
          max_selection_depth(children, frags, Map.put(seen, name, true), current)
      end
    end
  end

  defp selection_depth(_other, _frags, _seen, current), do: current
end
