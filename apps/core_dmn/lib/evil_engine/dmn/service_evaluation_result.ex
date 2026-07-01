defmodule EvilEngine.DMN.ServiceEvaluationResult do
  @moduledoc """
  Result of a Decision Service evaluation.

  Contains only the output decision results (encapsulated decisions
  are internal implementation details and not exposed).
  """

  alias EvilEngine.DMN.EvaluationTrace

  @type t :: %__MODULE__{
          service_id: String.t(),
          service_name: String.t() | nil,
          outputs: %{String.t() => term()},
          trace: EvaluationTrace.t(),
          evaluated_at: DateTime.t(),
          duration_microseconds: non_neg_integer()
        }

  @enforce_keys [:service_id, :outputs, :trace, :evaluated_at, :duration_microseconds]
  defstruct [
    :service_id,
    :service_name,
    :outputs,
    :trace,
    :evaluated_at,
    :duration_microseconds
  ]

  @spec to_json_map(t()) :: map()
  def to_json_map(%__MODULE__{} = result) do
    %{
      service_id: result.service_id,
      service_name: result.service_name,
      outputs: result.outputs,
      trace: EvaluationTrace.to_json_map(result.trace),
      evaluated_at: DateTime.to_iso8601(result.evaluated_at),
      duration_microseconds: result.duration_microseconds
    }
  end
end
