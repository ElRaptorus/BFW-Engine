defmodule BfwEngine.DMN.Evaluator.DependencyResolver do
  @moduledoc """
  Resolves DRG decision evaluation order via topological sort over
  `InformationRequirement.required_decision_id` edges.
  """

  alias BfwEngine.DMN.Model.Decision
  alias BfwEngine.DMN.Model.Definitions
  alias BfwEngine.DMN.QualifiedReference

  # Dialyzer cannot see through MapSet opaque types when used in plain maps.
  # The code is correct; MapSet.member?/put/delete are the only accessors.
  @dialyzer {:no_opaque, resolve_evaluation_order: 2}

  @spec resolve_evaluation_order(String.t(), Definitions.t()) ::
          {:ok, [String.t()]}
          | {:error, :drg_cycle, %{decision_ids: [String.t()]}}
          | {:error, :missing_required_decision,
             %{decision_id: String.t(), required_by: String.t()}}
  def resolve_evaluation_order(target_decision_id, %Definitions{decisions: decisions}) do
    decisions_by_id = Map.new(decisions, &{&1.id, &1})

    initial_state = %{
      visited: MapSet.new(),
      visiting: MapSet.new(),
      path: [],
      evaluation_order: []
    }

    case visit_decision(target_decision_id, decisions_by_id, initial_state) do
      {:ok, state} ->
        {:ok, Enum.reverse(state.evaluation_order)}

      {:error, _, _} = error ->
        error
    end
  end

  defp visit_decision(decision_id, decisions_by_id, state) do
    if MapSet.member?(state.visited, decision_id) do
      {:ok, state}
    else
      do_visit_decision(decision_id, decisions_by_id, state)
    end
  end

  defp do_visit_decision(decision_id, decisions_by_id, state) do
    if MapSet.member?(state.visiting, decision_id) do
      cycle_decision_ids = extract_cycle_decision_ids(decision_id, state.path)
      {:error, :drg_cycle, %{decision_ids: cycle_decision_ids}}
    else
      %Decision{} = decision = Map.fetch!(decisions_by_id, decision_id)
      dependency_decision_ids = required_decision_ids(decision)

      visiting_state = %{
        state
        | visiting: MapSet.put(state.visiting, decision_id),
          path: [decision_id | state.path]
      }

      with :ok <-
             validate_required_decisions_exist(
               dependency_decision_ids,
               decisions_by_id,
               decision_id
             ),
           {:ok, visited_state} <-
             visit_dependency_list(dependency_decision_ids, decisions_by_id, visiting_state) do
        {:ok,
         %{
           visited_state
           | visited: MapSet.put(visited_state.visited, decision_id),
             visiting: MapSet.delete(visited_state.visiting, decision_id),
             path: tl(visited_state.path),
             evaluation_order: [decision_id | visited_state.evaluation_order]
         }}
      end
    end
  end

  defp visit_dependency_list([], _decisions_by_id, state), do: {:ok, state}

  defp visit_dependency_list([dependency_id | rest], decisions_by_id, state) do
    case visit_decision(dependency_id, decisions_by_id, state) do
      {:ok, state} ->
        visit_dependency_list(rest, decisions_by_id, state)

      {:error, _, _} = error ->
        error
    end
  end

  defp validate_required_decisions_exist([], _decisions_by_id, _requiring_decision_id),
    do: :ok

  defp validate_required_decisions_exist(
         [dependency_id | rest],
         decisions_by_id,
         requiring_decision_id
       ) do
    if Map.has_key?(decisions_by_id, dependency_id) do
      validate_required_decisions_exist(rest, decisions_by_id, requiring_decision_id)
    else
      {:error, :missing_required_decision,
       %{decision_id: dependency_id, required_by: requiring_decision_id}}
    end
  end

  defp required_decision_ids(%Decision{information_requirements: requirements}) do
    requirements
    |> Enum.map(& &1.required_decision_id)
    |> Enum.reject(fn id -> is_nil(id) or QualifiedReference.imported?(id) end)
  end

  defp extract_cycle_decision_ids(cycle_start_decision_id, path) do
    {prefix, _} =
      Enum.split_while(path, fn decision_id -> decision_id != cycle_start_decision_id end)

    prefix ++ [cycle_start_decision_id]
  end
end
