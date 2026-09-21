defmodule BfwEngine.BPMN.Model.Lane do
  @moduledoc """
  A `<bpmn:lane>` inside a lane set, mapping flow node IDs to
  a named lane (used for authorization via lane-as-claim).
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          flow_node_refs: [String.t()]
        }

  @enforce_keys [:id]
  defstruct [:id, :name, flow_node_refs: []]
end

defmodule BfwEngine.BPMN.Model.DataObject do
  @moduledoc """
  A `<bpmn:dataObject>` — the actual data entity declaration.

  Not to be confused with `DataObjectReference`, which is the visual
  element on the diagram that points to this object.

  `value_contract` holds an optional JSON Schema from `<bfw:valueContract>`
  used to validate values written via Data Output Associations.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          item_subject_ref: String.t() | nil,
          value_contract: map() | nil
        }

  @enforce_keys [:id]
  defstruct [:id, :name, :item_subject_ref, :value_contract]
end

defmodule BfwEngine.BPMN.Model.DataAssociation do
  @moduledoc """
  A `<bpmn:dataInputAssociation>` or `<bpmn:dataOutputAssociation>`.

  Direction is implicit from which list the association lives in
  (`data_input_associations` vs `data_output_associations` on FlowNode).

  - DIA: `source_ref` = DataObjectReference, `target_ref` = nil
  - DOA: `source_ref` = nil, `target_ref` = DataObjectReference
  - `value_expression` is an optional FEEL expression for DOA value projection
  """

  @type t :: %__MODULE__{
          id: String.t(),
          source_ref: String.t() | nil,
          target_ref: String.t() | nil,
          value_expression: String.t() | nil
        }

  @enforce_keys [:id]
  defstruct [:id, :source_ref, :target_ref, :value_expression]
end

defmodule BfwEngine.BPMN.Model.DataObjectReference do
  @moduledoc """
  A `<bpmn:dataObjectReference>` — the visual diagram element.

  Multiple references can point to the same `DataObject` via
  `data_object_ref`. Associations connect to references, not objects.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          data_object_ref: String.t() | nil,
          data_state: String.t() | nil
        }

  @enforce_keys [:id]
  defstruct [:id, :name, :data_object_ref, :data_state]
end

defmodule BfwEngine.BPMN.Model.Association do
  @moduledoc """
  A `<bpmn:association>` linking two BPMN elements.

  Used primarily for compensation: a directed association connects a
  Compensation Boundary Event (source) to an `isForCompensation` handler
  activity (target). The model-build step resolves these into
  `compensation_handler_id` on the boundary's `FlowNodeData.BoundaryEvent`.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          source_ref: String.t() | nil,
          target_ref: String.t() | nil,
          association_direction: String.t() | nil
        }

  @enforce_keys [:id]
  defstruct [:id, :source_ref, :target_ref, :association_direction]
end

defmodule BfwEngine.BPMN.Model.Mapping do
  @moduledoc """
  An input or output mapping for Call Activities (and potentially
  MI collection mappings).

  `source` is a FEEL expression evaluated against the caller context.
  `target` is the variable name in the destination scope.
  """

  @type t :: %__MODULE__{
          source: String.t(),
          target: String.t()
        }

  @enforce_keys [:source, :target]
  defstruct [:source, :target]
end

defmodule BfwEngine.BPMN.Model.Extension do
  @moduledoc """
  A generic extension element preserved from `<bpmn:extensionElements>`.

  Captures anything the parser doesn't otherwise consume, so that
  downstream consumers can access custom vendor extensions.
  """

  @type t :: %__MODULE__{
          key: String.t(),
          value: String.t() | nil,
          attributes: %{String.t() => String.t()},
          children: [t()]
        }

  @enforce_keys [:key]
  defstruct [:key, :value, attributes: %{}, children: []]
end

defmodule BfwEngine.BPMN.Model.DataContract do
  @moduledoc """
  A JSON Schema data contract attached to a flow node.

  `direction` is `:input` or `:output` from the element's perspective.
  `json_schema` is the raw JSON Schema map. `compiled_schema` holds
  the precompiled `ExJsonSchema.Schema.Root.t()` (populated at deploy
  time, nil during initial parse).
  """

  @type t :: %__MODULE__{
          direction: :input | :output,
          json_schema: map(),
          compiled_schema: ExJsonSchema.Schema.Root.t() | nil
        }

  @enforce_keys [:direction, :json_schema]
  defstruct [:direction, :json_schema, :compiled_schema]
end

defmodule BfwEngine.BPMN.Model.LinterRulesetScore do
  @moduledoc """
  An `<bfw:LinterRulesetScore>` entry carried on the **definitions**
  (`definitions/extensionElements/bfw:Properties/bfw:LinterRulesetScore`).

  This matches the authoritative Studio contract emitted by
  `UpdateBfwLinterRulesetScoreHandler.ts` (ESP-D17). Every field is a
  string attribute on the XML element; numeric fields are parsed from their
  bare-string form (e.g. `scorePercent="92.5"`, no `%`). Read at deploy time
  by the linter-gate to accept or reject a process version deployment.
  """

  @type t :: %__MODULE__{
          ruleset_id: String.t(),
          score_percent: number() | nil,
          compliance_status: String.t() | nil,
          computed_at_iso: String.t() | nil,
          schema_version: String.t() | nil,
          max_points: number() | nil,
          penalty_points: number() | nil,
          raw_error_findings: non_neg_integer() | nil,
          raw_warning_findings: non_neg_integer() | nil
        }

  @enforce_keys [:ruleset_id]
  defstruct [
    :ruleset_id,
    :score_percent,
    :compliance_status,
    :computed_at_iso,
    :schema_version,
    :max_points,
    :penalty_points,
    :raw_error_findings,
    :raw_warning_findings
  ]
end

defmodule BfwEngine.BPMN.Model.MultiInstance do
  @moduledoc """
  Multi-instance loop characteristics for a flow node.

  The parser supports both standard BPMN `<bpmn:multiInstanceLoopCharacteristics>`
  attributes and `bfw:*` extensions, preferring the extension when both
  are present.

  `loopCardinality` is parsed into `loop_cardinality` and rejected at
  deploy time (`:loop_cardinality_not_supported`). Iteration count is
  exclusively determined by the input collection length.

  The `compiled_*` fields are reserved for future precompilation support.
  They are currently always `nil` because MI/Loop FEEL expressions
  reference runtime context variables (`token.*`, `loop.*`) whose shape
  is unknown at deploy time. The handlers use `Expressions.eval/2`
  (one-shot parse+evaluate) instead.
  """

  @type t :: %__MODULE__{
          is_sequential: boolean(),
          collection_expression: String.t() | nil,
          element_variable: String.t() | nil,
          completion_condition: String.t() | nil,
          output_collection: String.t() | nil,
          output_element_variable: String.t() | nil,
          loop_break_condition: String.t() | nil,
          loop_interval: String.t() | nil,
          max_iterations: non_neg_integer() | nil,
          loop_cardinality: String.t() | nil,
          compiled_collection: reference() | nil,
          compiled_output_collection: reference() | nil,
          compiled_completion_condition: reference() | nil,
          compiled_loop_break_condition: reference() | nil
        }

  defstruct is_sequential: false,
            collection_expression: nil,
            element_variable: nil,
            completion_condition: nil,
            output_collection: nil,
            output_element_variable: nil,
            loop_break_condition: nil,
            loop_interval: nil,
            max_iterations: nil,
            loop_cardinality: nil,
            compiled_collection: nil,
            compiled_output_collection: nil,
            compiled_completion_condition: nil,
            compiled_loop_break_condition: nil
end

defmodule BfwEngine.BPMN.Model.StandardLoop do
  @moduledoc """
  Standard loop characteristics (`<bpmn:standardLoopCharacteristics>`) for
  a flow node.

  When `test_before` is `true`, the loop evaluates `loop_condition` before
  the first iteration (while-do). When `false` (default), the first iteration
  runs unconditionally and the condition is checked afterwards (do-while).

  `loop_maximum` is an optional hard cap on iteration count.
  `loop_interval` is an optional ISO 8601 duration between iterations,
  essential for polling/healthcheck patterns.

  `compiled_loop_condition` is reserved for future precompilation support.
  It is currently always `nil` — the handler uses `Expressions.eval/2`
  (one-shot parse+evaluate) because the expression references runtime
  context variables (`token.*`, `loop.*`).
  """

  @type t :: %__MODULE__{
          test_before: boolean(),
          loop_condition: String.t() | nil,
          loop_maximum: non_neg_integer() | nil,
          loop_interval: String.t() | nil,
          compiled_loop_condition: reference() | nil
        }

  defstruct test_before: false,
            loop_condition: nil,
            loop_maximum: nil,
            loop_interval: nil,
            compiled_loop_condition: nil
end
