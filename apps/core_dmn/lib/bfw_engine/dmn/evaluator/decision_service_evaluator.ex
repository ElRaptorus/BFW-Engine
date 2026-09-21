defmodule BfwEngine.DMN.Evaluator.DecisionServiceEvaluator do
  @moduledoc """
  Evaluates a Decision Service within a DMN model.

  A Decision Service defines a boundary around a subset of the DRG.
  Evaluation proceeds as follows:

  1. Resolve the service by ID
  2. Build a scoped sub-DRG from output + encapsulated decisions
  3. Bind provided input data
  4. Pre-evaluate input decisions (external to the service)
  5. Evaluate encapsulated decisions in dependency order
  6. Evaluate output decisions
  7. Return only output decision results
  """

  alias BfwEngine.DMN.EvaluationTrace
  alias BfwEngine.DMN.Evaluator
  alias BfwEngine.DMN.Evaluator.DependencyResolver
  alias BfwEngine.DMN.Model.Decision
  alias BfwEngine.DMN.Model.DecisionService
  alias BfwEngine.DMN.Model.Definitions
  alias BfwEngine.DMN.ServiceEvaluationResult

  @spec evaluate(Definitions.t(), String.t(), map(), Evaluator.evaluate_opts()) ::
          {:ok, ServiceEvaluationResult.t()} | {:error, atom(), map()}
  def evaluate(%Definitions{} = definitions, service_id, input_context, opts \\ []) do
    start_time = System.monotonic_time(:microsecond)

    with {:ok, service} <- resolve_service(definitions, service_id),
         :ok <- verify_decision_references(service, definitions),
         :ok <- validate_service_input_data(service, definitions, input_context),
         {:ok, context_with_inputs} <-
           evaluate_input_decisions(service, definitions, input_context, opts),
         {:ok, traces, output_results} <-
           evaluate_service_sub_drg(service, definitions, context_with_inputs, opts) do
      elapsed = System.monotonic_time(:microsecond) - start_time

      result = %ServiceEvaluationResult{
        service_id: service.id,
        service_name: service.name,
        outputs: output_results,
        trace: %EvaluationTrace{decisions: traces},
        evaluated_at: DateTime.utc_now(),
        duration_microseconds: elapsed
      }

      {:ok, result}
    end
  end

  defp resolve_service(%Definitions{decision_services: services}, service_id) do
    case Enum.find(services, &(&1.id == service_id)) do
      nil -> {:error, :service_not_found, %{service_id: service_id}}
      service -> {:ok, service}
    end
  end

  defp validate_service_input_data(%DecisionService{input_data: []}, _definitions, _input_context) do
    :ok
  end

  defp validate_service_input_data(%DecisionService{input_data: input_data_ids} = service, definitions, input_context) do
    input_data_by_id = Map.new(definitions.input_data, &{&1.id, &1})
    required_names = resolve_input_data_names(input_data_ids, input_data_by_id)

    case find_missing_service_inputs(required_names, input_context) do
      [] ->
        :ok

      missing ->
        {:error, :missing_service_input,
         %{
           service_id: service.id,
           missing_inputs: missing,
           message: "Decision Service '#{service.id}' requires inputs: #{Enum.join(missing, ", ")}"
         }}
    end
  end

  defp resolve_input_data_names(input_data_ids, input_data_by_id) do
    Enum.map(input_data_ids, fn id ->
      case Map.fetch(input_data_by_id, id) do
        {:ok, input_data} -> input_data.name
        :error -> id
      end
    end)
  end

  defp find_missing_service_inputs(required_names, input_context) do
    Enum.reject(required_names, fn name ->
      Map.has_key?(input_context, name) and not is_nil(Map.get(input_context, name))
    end)
  end

  defp verify_decision_references(service, definitions) do
    decision_ids = MapSet.new(definitions.decisions, & &1.id)

    all_decision_refs =
      service.output_decisions ++
        service.encapsulated_decisions ++
        service.input_decisions

    case Enum.find(all_decision_refs, fn ref -> not MapSet.member?(decision_ids, ref) end) do
      nil -> :ok
      missing_ref -> {:error, :missing_service_decision, %{decision_id: missing_ref, service_id: service.id}}
    end
  end

  defp evaluate_input_decisions(
         %DecisionService{input_decisions: []},
         _definitions,
         input_context,
         _opts
       ) do
    {:ok, input_context}
  end

  defp evaluate_input_decisions(
         %DecisionService{input_decisions: input_decision_ids},
         definitions,
         input_context,
         opts
       ) do
    decisions_by_id = Map.new(definitions.decisions, &{&1.id, &1})

    Enum.reduce_while(input_decision_ids, {:ok, input_context}, fn decision_id, {:ok, context} ->
      evaluate_single_input_decision(decision_id, decisions_by_id, definitions, context, opts)
    end)
  end

  defp evaluate_single_input_decision(decision_id, decisions_by_id, definitions, context, opts) do
    case Evaluator.evaluate(definitions, decision_id, context, opts) do
      {:ok, result} ->
        decision = Map.fetch!(decisions_by_id, decision_id)
        variable_name = Decision.output_variable_name(decision)
        {:cont, {:ok, Map.put(context, variable_name, result.result)}}

      {:error, _, _} = error ->
        {:halt, error}
    end
  end

  defp evaluate_service_sub_drg(service, definitions, context, opts) do
    output_set = MapSet.new(service.output_decisions)

    all_relevant_ids =
      service.output_decisions ++
        service.encapsulated_decisions ++
        service.input_decisions

    relevant_decisions =
      Enum.filter(definitions.decisions, fn decision -> decision.id in all_relevant_ids end)

    scoped_definitions = %{definitions | decisions: relevant_decisions}

    evaluatable_ids =
      MapSet.new(service.output_decisions ++ service.encapsulated_decisions)

    with {:ok, evaluation_order} <- resolve_sub_drg_order(service, scoped_definitions) do
      filtered_order = Enum.filter(evaluation_order, &MapSet.member?(evaluatable_ids, &1))
      evaluate_sub_drg_chain(filtered_order, scoped_definitions, context, output_set, opts)
    end
  end

  defp resolve_sub_drg_order(service, scoped_definitions) do
    service.output_decisions
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn output_id, {:ok, accumulated_order, seen} ->
      case DependencyResolver.resolve_evaluation_order(output_id, scoped_definitions) do
        {:ok, order} ->
          new_ids = Enum.reject(order, &MapSet.member?(seen, &1))
          new_seen = Enum.reduce(new_ids, seen, &MapSet.put(&2, &1))
          {:cont, {:ok, accumulated_order ++ new_ids, new_seen}}

        {:error, _, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, order, _seen} -> {:ok, order}
      {:error, _, _} = error -> error
    end
  end

  defp evaluate_sub_drg_chain(evaluation_order, scoped_definitions, context, output_set, opts) do
    decisions_by_id = Map.new(scoped_definitions.decisions, &{&1.id, &1})
    initial_state = {:ok, [], MapSet.new(), context}

    result =
      Enum.reduce_while(evaluation_order, initial_state, fn decision_id, accumulator ->
        evaluate_sub_drg_step(
          decision_id, accumulator, decisions_by_id, scoped_definitions, opts
        )
      end)

    case result do
      {:ok, traces, _seen_ids, final_context} ->
        output_results = extract_output_results(output_set, decisions_by_id, final_context)
        {:ok, traces, output_results}

      {:error, _} = error ->
        error

      {:error, _, _} = error ->
        error
    end
  end

  defp evaluate_sub_drg_step(
         decision_id,
         {:ok, traces, seen_ids, accumulated_context},
         decisions_by_id,
         scoped_definitions,
         opts
       ) do
    decision = Map.fetch!(decisions_by_id, decision_id)

    case Evaluator.evaluate(scoped_definitions, decision_id, accumulated_context, opts) do
      {:ok, evaluation_result} ->
        variable_name = Decision.output_variable_name(decision)
        updated_context = Map.put(accumulated_context, variable_name, evaluation_result.result)

        new_traces =
          Enum.reject(evaluation_result.trace.decisions, fn decision_trace ->
            MapSet.member?(seen_ids, decision_trace.decision_model_id)
          end)

        updated_seen =
          Enum.reduce(new_traces, seen_ids, fn decision_trace, seen ->
            MapSet.put(seen, decision_trace.decision_model_id)
          end)

        {:cont, {:ok, traces ++ new_traces, updated_seen, updated_context}}

      {:error, _, _} = error ->
        {:halt, error}
    end
  end

  defp extract_output_results(output_set, decisions_by_id, context) do
    output_set
    |> Enum.reduce(%{}, fn decision_id, accumulated ->
      decision = Map.fetch!(decisions_by_id, decision_id)
      variable_name = Decision.output_variable_name(decision)
      Map.put(accumulated, variable_name, Map.get(context, variable_name))
    end)
  end
end
