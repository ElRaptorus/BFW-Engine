defmodule EvilEngine.DMN.EvaluationResult do
  @moduledoc """
  The complete result of a DMN decision evaluation.

  Returned by `Evaluator.evaluate/4`, the API facade's
  `evaluate_decision/3`, and the REST `/decisions/{id}/evaluate`
  endpoint.

  Phase 7 enrichment fields:
  - `definitions_id` — `Definitions.id` from the parsed model
  - `definitions_namespace` — `Definitions.namespace`
  - `decision_version_id` — deployed version ID (from BRT or REST caller)
  """

  alias EvilEngine.DMN.EvaluationTrace

  @type t :: %__MODULE__{
          decision_model_id: String.t(),
          decision_name: String.t() | nil,
          hit_policy: atom(),
          result: term(),
          matched_rules: [String.t()],
          trace: EvaluationTrace.t(),
          evaluated_at: DateTime.t(),
          duration_microseconds: non_neg_integer(),
          definitions_id: String.t() | nil,
          definitions_namespace: String.t() | nil,
          decision_version_id: String.t() | nil
        }

  @enforce_keys [
    :decision_model_id,
    :hit_policy,
    :result,
    :trace,
    :evaluated_at,
    :duration_microseconds
  ]
  defstruct [
    :decision_model_id,
    :decision_name,
    :hit_policy,
    :result,
    :trace,
    :evaluated_at,
    :duration_microseconds,
    :definitions_id,
    :definitions_namespace,
    :decision_version_id,
    matched_rules: []
  ]

  @doc "Serialize the result to a JSON-safe map (for REST responses and FNI type_properties)."
  @spec to_json_map(t()) :: map()
  def to_json_map(%__MODULE__{} = result) do
    %{
      decision_model_id: result.decision_model_id,
      decision_name: result.decision_name,
      hit_policy: Atom.to_string(result.hit_policy),
      result: result.result,
      matched_rules: result.matched_rules,
      trace: EvaluationTrace.to_json_map(result.trace),
      evaluated_at: DateTime.to_iso8601(result.evaluated_at),
      duration_microseconds: result.duration_microseconds,
      definitions_id: result.definitions_id,
      definitions_namespace: result.definitions_namespace,
      decision_version_id: result.decision_version_id
    }
  end
end
