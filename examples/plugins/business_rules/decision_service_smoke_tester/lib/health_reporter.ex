defmodule Examples.BusinessRules.DecisionServiceSmokeTester.HealthReporter do
  @moduledoc """
  Pure helpers that turn per-service smoke test outcomes into a structured health report.
  """

  alias EvilEngine.DMN.ServiceEvaluationResult

  @type test_result :: %{
          model_id: String.t(),
          service_id: String.t(),
          outcome: {:ok, ServiceEvaluationResult.t() | map()} | {:error, term()}
        }

  @doc "Builds a summary health report from a list of per-service test results."
  @spec build([test_result()]) :: map()
  def build(test_results) do
    details = Enum.map(test_results, &build_detail/1)
    healthy_count = Enum.count(details, &(&1.status == :healthy))
    unhealthy_count = Enum.count(details, &(&1.status == :unhealthy))
    unique_model_ids = details |> Enum.map(& &1.model_id) |> Enum.uniq()

    %{
      timestamp: DateTime.utc_now(),
      total_models: length(unique_model_ids),
      total_services: length(details),
      healthy: healthy_count,
      unhealthy: unhealthy_count,
      details: details
    }
  end

  defp build_detail(%{model_id: model_id, service_id: service_id, outcome: {:ok, result}}) do
    %{
      model_id: model_id,
      service_id: service_id,
      status: :healthy,
      duration_us: extract_duration_microseconds(result),
      result_shape: summarize_result_shape(result)
    }
  end

  defp build_detail(%{model_id: model_id, service_id: service_id, outcome: {:error, reason}}) do
    %{
      model_id: model_id,
      service_id: service_id,
      status: :unhealthy,
      error: reason
    }
  end

  defp extract_duration_microseconds(%ServiceEvaluationResult{duration_microseconds: duration}) do
    duration
  end

  defp extract_duration_microseconds(result) when is_map(result) do
    Map.get(result, :duration_microseconds) ||
      Map.get(result, "durationMicroseconds") ||
      0
  end

  defp summarize_result_shape(%ServiceEvaluationResult{outputs: outputs}) do
    summarize_outputs(outputs)
  end

  defp summarize_result_shape(result) when is_map(result) do
    outputs =
      Map.get(result, :outputs) || Map.get(result, "outputs") || %{}

    summarize_outputs(outputs)
  end

  defp summarize_outputs(outputs) when is_map(outputs) do
    %{
      output_count: map_size(outputs),
      output_keys: outputs |> Map.keys() |> Enum.sort()
    }
  end
end
