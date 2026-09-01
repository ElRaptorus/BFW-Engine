defmodule Examples.BusinessRules.DecisionAuditReporter.BoundaryTester do
  @moduledoc """
  Runs configured boundary-case inputs through `facade.decisions.evaluate/3`
  to complement runtime coverage collected from live process instances.
  """

  alias EvilEngine.EngineFacade

  @type boundary_input :: %{test_case: String.t(), input: map()}

  @type decision_model_config :: %{
          decision_ref: String.t(),
          boundary_inputs: [boundary_input()]
        }

  @type boundary_test_result :: %{
          test_case: String.t(),
          input: map(),
          result: term() | nil,
          error: String.t() | nil
        }

  @doc "Evaluates every boundary input for each decision model."
  @spec test_all(EngineFacade.t(), [decision_model_config()]) :: %{String.t() => [boundary_test_result()]}
  def test_all(%EngineFacade{decisions: decisions}, decision_models) do
    Map.new(decision_models, fn model ->
      {model.decision_ref, evaluate_model(decisions, model)}
    end)
  end

  defp evaluate_model(decisions, model) do
    Enum.map(model.boundary_inputs, fn %{test_case: test_case, input: input} ->
      evaluate_one(decisions, model.decision_ref, test_case, input)
    end)
  end

  defp evaluate_one(decisions, decision_ref, test_case, input) do
    try do
      case decisions.evaluate.(decision_ref, input, []) do
        {:ok, evaluation} ->
          %{
            test_case: test_case,
            input: input,
            result: evaluation_result(evaluation),
            error: nil
          }

        {:error, reason} ->
          %{test_case: test_case, input: input, result: nil, error: inspect(reason)}
      end
    rescue
      exception ->
        %{
          test_case: test_case,
          input: input,
          result: nil,
          error: Exception.message(exception)
        }
    end
  end

  defp evaluation_result(%{result: result}), do: result

  defp evaluation_result(evaluation) when is_map(evaluation) do
    Map.get(evaluation, "result")
  end

  defp evaluation_result(_other), do: nil
end
