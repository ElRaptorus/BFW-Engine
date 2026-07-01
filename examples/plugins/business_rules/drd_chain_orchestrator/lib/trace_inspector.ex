defmodule Examples.BusinessRules.DrdChainOrchestrator.TraceInspector do
  @moduledoc """
  Pure functions that turn a DMN `EvaluationTrace` JSON map into a step-by-step
  decision chain and a human-readable summary.
  """

  alias EvilEngine.DMN.EvaluationTrace

  @doc """
  Formats an evaluation trace into an ordered list of decision steps with BKM
  invocation detail. Accepts traces with atom or string keys.
  """
  @spec format_chain(map() | EvaluationTrace.t()) :: [map()]
  def format_chain(%EvaluationTrace{} = trace) do
    trace
    |> EvaluationTrace.to_json_map()
    |> format_chain()
  end

  def format_chain(trace) when is_map(trace) do
    trace
    |> stringify_map_keys()
    |> Map.get("decisions", [])
    |> Enum.with_index(1)
    |> Enum.map(fn {decision, index} ->
      bkm_info = format_bkm_traces(Map.get(decision, "bkm_traces", []))

      %{
        step: index,
        decision: decision["decision_name"],
        hit_policy: decision["hit_policy"],
        result: decision["result"],
        duration_us: decision["duration_microseconds"],
        bkm_invocations: bkm_info,
        input_count: length(Map.get(decision, "inputs", []))
      }
    end)
  end

  def format_chain(_invalid_trace), do: []

  @doc "Builds a multi-line text summary from a formatted chain list."
  @spec format_summary([map()]) :: String.t()
  def format_summary(chain) when is_list(chain) do
    if chain == [] do
      "DRD evaluation chain: (empty)"
    else
      header = "DRD evaluation chain (#{length(chain)} decisions):"

      lines =
        Enum.map(chain, fn step ->
          bkm_count = count_bkm_invocations(step[:bkm_invocations] || [])
          decision_name = step[:decision] || "unknown"
          hit_policy = step[:hit_policy] || "?"
          duration_us = step[:duration_us] || 0
          input_count = step[:input_count] || 0

          "  Step #{step[:step]}: #{decision_name} [#{hit_policy}] " <>
            "result=#{inspect(step[:result])} " <>
            "inputs=#{input_count} bkm_invocations=#{bkm_count} duration_us=#{duration_us}"
        end)

      Enum.join([header | lines], "\n")
    end
  end

  defp format_bkm_traces(bkm_traces) when is_list(bkm_traces) do
    Enum.map(bkm_traces, fn bkm ->
      bkm = stringify_map_keys(bkm)

      %{
        bkm_name: bkm["bkm_name"],
        parameters:
          Enum.map(bkm["formal_parameters"] || [], fn parameter ->
            parameter = stringify_map_keys(parameter)
            {parameter["name"], parameter["bound_value"]}
          end),
        result: bkm["result"],
        nested_bkms: format_bkm_traces(Map.get(bkm, "dependent_bkm_traces", []))
      }
    end)
  end

  defp format_bkm_traces(_invalid), do: []

  defp count_bkm_invocations(bkm_invocations) when is_list(bkm_invocations) do
    Enum.reduce(bkm_invocations, 0, fn bkm, count ->
      nested_count = count_bkm_invocations(Map.get(bkm, :nested_bkms, []))
      count + 1 + nested_count
    end)
  end

  defp stringify_map_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      string_key =
        case key do
          key when is_binary(key) -> key
          key when is_atom(key) -> Atom.to_string(key)
          other -> to_string(other)
        end

      {string_key, stringify_map_keys(nested_value)}
    end)
  end

  defp stringify_map_keys(value) when is_list(value) do
    Enum.map(value, &stringify_map_keys/1)
  end

  defp stringify_map_keys(value), do: value
end
