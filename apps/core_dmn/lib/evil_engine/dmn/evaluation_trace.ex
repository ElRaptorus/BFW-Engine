defmodule EvilEngine.DMN.EvaluationTrace do
  @moduledoc """
  Structured execution trace for DMN evaluations.

  Contains an ordered list of `DecisionTrace` entries — one per
  evaluated decision in DRG dependency order. Single-decision models
  produce a list with exactly one entry.

  Phase 7 additions:
  - `input_coercions` — per-input coercion trace at the root level
  - `BkmTrace` — recursive BKM invocation trace on each `DecisionTrace`
  - `ImportTrace` — cross-model import trace wrapping full sub-DRG traces
  - `CoercionTrace` — input type coercion visibility
  """

  alias __MODULE__.CoercionTrace
  alias __MODULE__.DecisionTrace

  @type t :: %__MODULE__{
          decisions: [DecisionTrace.t()],
          input_coercions: [CoercionTrace.t()]
        }

  defstruct decisions: [], input_coercions: []

  @spec to_json_map(t()) :: map()
  def to_json_map(%__MODULE__{} = trace) do
    %{
      decisions: Enum.map(trace.decisions, &DecisionTrace.to_json_map/1),
      input_coercions: Enum.map(trace.input_coercions, &CoercionTrace.to_json_map/1)
    }
  end

  defmodule BkmTrace do
    @moduledoc "Trace of a single BKM invocation including nested BKM chains."

    @type t :: %__MODULE__{
            bkm_id: String.t(),
            bkm_name: String.t() | nil,
            formal_parameters: [%{name: String.t(), bound_value: term()}],
            result: term(),
            duration_microseconds: non_neg_integer(),
            dependent_bkm_traces: [t()]
          }

    defstruct [
      :bkm_id,
      :bkm_name,
      formal_parameters: [],
      result: nil,
      duration_microseconds: 0,
      dependent_bkm_traces: []
    ]

    @spec to_json_map(t()) :: map()
    def to_json_map(%__MODULE__{} = trace) do
      %{
        bkm_id: trace.bkm_id,
        bkm_name: trace.bkm_name,
        formal_parameters:
          Enum.map(trace.formal_parameters, fn param ->
            %{name: param.name, bound_value: param.bound_value}
          end),
        result: trace.result,
        duration_microseconds: trace.duration_microseconds,
        dependent_bkm_traces: Enum.map(trace.dependent_bkm_traces, &to_json_map/1)
      }
    end
  end

  defmodule ImportTrace do
    @moduledoc "Trace of a cross-model import wrapping the full sub-DRG evaluation."

    alias EvilEngine.DMN.EvaluationTrace, as: ParentTrace

    @type t :: %__MODULE__{
            namespace: String.t(),
            decision_id: String.t(),
            source_definitions_id: String.t(),
            evaluation_trace: ParentTrace.t(),
            result: term(),
            duration_microseconds: non_neg_integer()
          }

    defstruct [
      :namespace,
      :decision_id,
      :source_definitions_id,
      :evaluation_trace,
      :result,
      duration_microseconds: 0
    ]

    @spec to_json_map(t()) :: map()
    def to_json_map(%__MODULE__{} = trace) do
      %{
        namespace: trace.namespace,
        decision_id: trace.decision_id,
        source_definitions_id: trace.source_definitions_id,
        evaluation_trace: ParentTrace.to_json_map(trace.evaluation_trace),
        result: trace.result,
        duration_microseconds: trace.duration_microseconds
      }
    end
  end

  defmodule CoercionTrace do
    @moduledoc "Trace of a single input type coercion (or non-coercion)."

    @type t :: %__MODULE__{
            input_name: String.t(),
            original_value: term(),
            coerced_value: term(),
            target_type: String.t(),
            coerced: boolean()
          }

    defstruct [:input_name, :original_value, :coerced_value, :target_type, coerced: false]

    @spec to_json_map(t()) :: map()
    def to_json_map(%__MODULE__{} = trace) do
      %{
        input_name: trace.input_name,
        original_value: trace.original_value,
        coerced_value: trace.coerced_value,
        target_type: trace.target_type,
        coerced: trace.coerced
      }
    end
  end

  defmodule DecisionTrace do
    @moduledoc "Trace for a single decision within an evaluation."

    alias EvilEngine.DMN.EvaluationTrace.BkmTrace
    alias EvilEngine.DMN.EvaluationTrace.ImportTrace
    alias EvilEngine.DMN.EvaluationTrace.InputTrace
    alias EvilEngine.DMN.EvaluationTrace.RuleTrace

    @type t :: %__MODULE__{
            decision_model_id: String.t(),
            decision_name: String.t() | nil,
            hit_policy: atom(),
            inputs: [InputTrace.t()],
            matched_rules: [RuleTrace.t()],
            unmatched_rules: [RuleTrace.t()],
            unmatched_rules_count: non_neg_integer(),
            result: term(),
            duration_microseconds: non_neg_integer(),
            warnings: [map()],
            bkm_traces: [BkmTrace.t()],
            import_traces: [ImportTrace.t()]
          }

    defstruct [
      :decision_model_id,
      :decision_name,
      :hit_policy,
      :result,
      :duration_microseconds,
      inputs: [],
      matched_rules: [],
      unmatched_rules: [],
      unmatched_rules_count: 0,
      warnings: [],
      bkm_traces: [],
      import_traces: []
    ]

    @spec to_json_map(t()) :: map()
    def to_json_map(%__MODULE__{} = trace) do
      base = %{
        decision_model_id: trace.decision_model_id,
        decision_name: trace.decision_name,
        hit_policy: Atom.to_string(trace.hit_policy),
        inputs: Enum.map(trace.inputs, &InputTrace.to_json_map/1),
        matched_rules: Enum.map(trace.matched_rules, &RuleTrace.to_json_map/1),
        unmatched_rules_count: trace.unmatched_rules_count,
        result: trace.result,
        duration_microseconds: trace.duration_microseconds,
        warnings: Enum.map(trace.warnings, &stringify_warning/1),
        bkm_traces: Enum.map(trace.bkm_traces, &BkmTrace.to_json_map/1),
        import_traces: Enum.map(trace.import_traces, &ImportTrace.to_json_map/1)
      }

      if trace.unmatched_rules == [] do
        base
      else
        Map.put(base, :unmatched_rules, Enum.map(trace.unmatched_rules, &RuleTrace.to_json_map/1))
      end
    end

    defp stringify_warning(warning) when is_map(warning) do
      Map.new(warning, fn
        {key, value} when is_atom(value) -> {key, Atom.to_string(value)}
        {key, value} -> {key, value}
      end)
    end
  end

  defmodule InputTrace do
    @moduledoc "Trace of a single input expression resolution."

    @type t :: %__MODULE__{
            input_id: String.t(),
            input_label: String.t() | nil,
            expression: String.t(),
            resolved_value: term()
          }

    defstruct [:input_id, :input_label, :expression, :resolved_value]

    @spec to_json_map(t()) :: map()
    def to_json_map(%__MODULE__{} = trace) do
      %{
        input_id: trace.input_id,
        input_label: trace.input_label,
        expression: trace.expression,
        resolved_value: trace.resolved_value
      }
    end
  end

  defmodule RuleTrace do
    @moduledoc "Trace of a matched rule with per-cell evaluations."

    alias EvilEngine.DMN.EvaluationTrace.InputEntryTrace

    @type t :: %__MODULE__{
            rule_id: String.t(),
            rule_index: non_neg_integer(),
            description: String.t() | nil,
            input_evaluations: [InputEntryTrace.t()],
            output_values: map()
          }

    defstruct [:rule_id, :rule_index, :description, input_evaluations: [], output_values: %{}]

    @spec to_json_map(t()) :: map()
    def to_json_map(%__MODULE__{} = trace) do
      %{
        rule_id: trace.rule_id,
        rule_index: trace.rule_index,
        description: trace.description,
        input_evaluations: Enum.map(trace.input_evaluations, &InputEntryTrace.to_json_map/1),
        output_values: trace.output_values
      }
    end
  end

  defmodule InputEntryTrace do
    @moduledoc "Trace of a single input entry (unary test) evaluation."

    @type t :: %__MODULE__{
            input_id: String.t(),
            expression: String.t(),
            tested_value: term(),
            matched: boolean()
          }

    defstruct [:input_id, :expression, :tested_value, :matched]

    @spec to_json_map(t()) :: map()
    def to_json_map(%__MODULE__{} = trace) do
      %{
        input_id: trace.input_id,
        expression: trace.expression,
        tested_value: trace.tested_value,
        matched: trace.matched
      }
    end
  end
end
