defmodule EvilEngine.BPMN.Model.FlowNode do
  @moduledoc """
  A polymorphic flow node in a BPMN process.

  `type` is an atom identifying the element kind (`:start_event`,
  `:user_task`, `:exclusive_gateway`, etc.).

  `type_data` is the corresponding `FlowNodeData.*` struct carrying
  element-specific fields. Runtime handlers pattern-match on it.
  """

  alias EvilEngine.BPMN.Model.DataAssociation
  alias EvilEngine.BPMN.Model.DataContract
  alias EvilEngine.BPMN.Model.MultiInstance
  alias EvilEngine.BPMN.Model.StandardLoop

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          type: atom(),
          type_data: struct(),
          incoming: [String.t()],
          outgoing: [String.t()],
          boundary_event_refs: [String.t()],
          data_contracts: [DataContract.t()],
          data_input_associations: [DataAssociation.t()],
          data_output_associations: [DataAssociation.t()],
          multi_instance: MultiInstance.t() | nil,
          standard_loop: StandardLoop.t() | nil,
          is_for_compensation: boolean(),
          documentation: String.t() | nil
        }

  @enforce_keys [:id, :type, :type_data]
  defstruct [
    :id,
    :name,
    :type,
    :type_data,
    :multi_instance,
    :standard_loop,
    :documentation,
    incoming: [],
    outgoing: [],
    boundary_event_refs: [],
    data_contracts: [],
    data_input_associations: [],
    data_output_associations: [],
    is_for_compensation: false
  ]
end

# ---------------------------------------------------------------------------
# FlowNodeData — Activities
# ---------------------------------------------------------------------------

defmodule EvilEngine.BPMN.Model.FlowNodeData.Task do
  @moduledoc "Untyped `<bpmn:task>` — pure pass-through."
  @type t :: %__MODULE__{}
  defstruct []
end

defmodule EvilEngine.BPMN.Model.FlowNodeData.UserTask do
  @moduledoc """
  `<bpmn:userTask>` with `evil:*` extensions for form fields,
  assignees, contracts, mappers, due date, and priority.

  `in_mappings` and `out_mappings` are lists of `Mapping` structs
  (FEEL source/target pairs) — same structure as Call Activity.
  """

  alias EvilEngine.BPMN.Model.Mapping

  @type t :: %__MODULE__{
          form_schema: list(map()) | nil,
          form_actions: list(map()) | nil,
          assignees_expression: String.t() | nil,
          payload_contract: map() | nil,
          result_contract: map() | nil,
          in_mappings: [Mapping.t()],
          out_mappings: [Mapping.t()],
          due_date: String.t() | nil,
          priority: integer() | nil
        }

  defstruct [
    :form_schema,
    :form_actions,
    :assignees_expression,
    :payload_contract,
    :result_contract,
    :due_date,
    :priority,
    in_mappings: [],
    out_mappings: []
  ]
end

defmodule EvilEngine.BPMN.Model.FlowNodeData.ServiceTask do
  @moduledoc """
  `<bpmn:serviceTask>` with extensions for dispatch, contracts, and mappers.

  `in_mappings` and `out_mappings` are lists of `Mapping` structs
  (FEEL source/target pairs), same structure as Call Activity.

  `implementation` is the BPMN 2.0 standard attribute on `<bpmn:serviceTask>`
  used as the handler dispatch key (e.g. `"http"`, a plugin-registered key).

  HTTP-specific extensions (for `implementation == "http"`):
  - `http_url` — target URL (static, required)
  - `http_method` — HTTP verb (static, default `"GET"`)
  - `http_body` — FEEL expression for request body
  - `http_auth_header` — FEEL expression for Authorization header
  - `http_response_headers` — FEEL expression for response header mapping
  """

  alias EvilEngine.BPMN.Model.Mapping

  @type t :: %__MODULE__{
          implementation: String.t() | nil,
          payload_contract: map() | nil,
          result_contract: map() | nil,
          in_mappings: [Mapping.t()],
          out_mappings: [Mapping.t()],
          http_url: String.t() | nil,
          http_method: String.t() | nil,
          http_body: String.t() | nil,
          http_auth_header: String.t() | nil,
          http_response_headers: String.t() | nil
        }

  defstruct [
    :implementation,
    :payload_contract,
    :result_contract,
    :http_url,
    :http_method,
    :http_body,
    :http_auth_header,
    :http_response_headers,
    in_mappings: [],
    out_mappings: []
  ]
end

defmodule EvilEngine.BPMN.Model.FlowNodeData.ManualTask do
  @moduledoc """
  `<bpmn:manualTask>`. Pass-through unless `require_confirmation`
  is true, in which case it waits for a `FinishUserTask` call.
  """

  @type t :: %__MODULE__{require_confirmation: boolean()}
  defstruct require_confirmation: false
end

defmodule EvilEngine.BPMN.Model.FlowNodeData.ScriptTask do
  @moduledoc """
  `<bpmn:scriptTask>` with inline FEEL script or plugin-dispatched named script.

  `scriptFormat` and `<script>` are standard BPMN 2.0 properties.
  `evil:scriptRef` is a custom extension element for plugin dispatch.

  When `script_ref` is set, the engine dispatches to the named script
  plugin registered under that key. Otherwise the inline `script` body
  is evaluated as FEEL. `script_ref` takes precedence when both are set.

  `scriptFormat` is stored for BPMN fidelity but not enforced by the
  runtime — inline scripts always evaluate as FEEL. Plugins can
  inspect it via `flow_node.type_data.script_format`.
  """

  alias EvilEngine.BPMN.Model.Mapping

  @type t :: %__MODULE__{
          script_format: String.t() | nil,
          script: String.t() | nil,
          script_ref: String.t() | nil,
          payload_contract: map() | nil,
          result_contract: map() | nil,
          in_mappings: [Mapping.t()],
          out_mappings: [Mapping.t()]
        }

  defstruct [
    :script_format,
    :script,
    :script_ref,
    :payload_contract,
    :result_contract,
    in_mappings: [],
    out_mappings: []
  ]
end

defmodule EvilEngine.BPMN.Model.FlowNodeData.BusinessRuleTask do
  @moduledoc """
  `<bpmn:businessRuleTask>` with two execution modes selected by the
  standard BPMN `implementation` attribute:

  - `"feel"` — Evaluate an inline FEEL expression from `<bpmn:script>`.
  - `"dmn"` — Resolve and evaluate a deployed DMN decision table via `evil:decisionRef`.
    When the DMN model contains multiple decisions, `evil:decisionElementId`
    specifies which `<decision>` element to evaluate as the root. When omitted
    the evaluator auto-resolves single-decision models.

  Plugin delegation (`implementation="plugin"`) was removed.
  The `rule_ref` field is retained for XML parsing but rejected by the
  validator if `implementation="plugin"` is used.

  `implementation` and `<bpmn:script>` are standard BPMN 2.0 properties.
  All `evil:*` fields are engine-specific extensions.
  """

  alias EvilEngine.BPMN.Model.Mapping

  @type t :: %__MODULE__{
          implementation: String.t() | nil,
          script: String.t() | nil,
          rule_ref: String.t() | nil,
          decision_ref: String.t() | nil,
          decision_element_id: String.t() | nil,
          result_variable: String.t() | nil,
          trace_unmatched_rules: boolean(),
          payload_contract: map() | nil,
          result_contract: map() | nil,
          in_mappings: [Mapping.t()],
          out_mappings: [Mapping.t()]
        }

  defstruct [
    :implementation,
    :script,
    :rule_ref,
    :decision_ref,
    :decision_element_id,
    :result_variable,
    :payload_contract,
    :result_contract,
    trace_unmatched_rules: false,
    in_mappings: [],
    out_mappings: []
  ]
end

defmodule EvilEngine.BPMN.Model.FlowNodeData.SendTask do
  @moduledoc """
  `<bpmn:sendTask>` — a simpler Service Task with built-in message
  throw. Uses the same message routing infrastructure as Message
  Throw events.
  """

  alias EvilEngine.BPMN.Model.Mapping

  @type t :: %__MODULE__{
          message_ref: String.t() | nil,
          payload_contract: map() | nil,
          in_mappings: [Mapping.t()],
          out_mappings: [Mapping.t()]
        }
  defstruct [:message_ref, :payload_contract, in_mappings: [], out_mappings: []]
end

defmodule EvilEngine.BPMN.Model.FlowNodeData.ReceiveTask do
  @moduledoc """
  `<bpmn:receiveTask>` — semantically equivalent to an Intermediate
  Message Catch Event at task level.

  Catch-side: uses `result_contract` to validate incoming data.
  A ReceiveTask does not send data, so it has no `payload_contract`.
  """

  alias EvilEngine.BPMN.Model.Mapping

  @type t :: %__MODULE__{
          message_ref: String.t() | nil,
          result_contract: map() | nil,
          in_mappings: [Mapping.t()],
          out_mappings: [Mapping.t()]
        }
  defstruct [:message_ref, :result_contract, in_mappings: [], out_mappings: []]
end

defmodule EvilEngine.BPMN.Model.FlowNodeData.CallActivity do
  @moduledoc """
  `<bpmn:callActivity>` — invokes another process.

  `in_mappings` and `out_mappings` are lists of `Mapping` structs
  where `source` is a FEEL expression and `target` is a variable name.

  `start_event_id` (from `<evil:startEventId>`) selects which Start Event
  the child process should begin at. Required when the child has multiple
  untyped Start Events; optional otherwise.
  """

  alias EvilEngine.BPMN.Model.Mapping

  @type t :: %__MODULE__{
          called_element: String.t() | nil,
          start_event_id: String.t() | nil,
          in_mappings: [Mapping.t()],
          out_mappings: [Mapping.t()]
        }

  defstruct [:called_element, :start_event_id, in_mappings: [], out_mappings: []]
end

defmodule EvilEngine.BPMN.Model.FlowNodeData.SubProcess do
  @moduledoc """
  `<bpmn:subProcess>`, `<bpmn:transaction>`, or `<bpmn:adHocSubProcess>` —
  embedded, event, transaction, or ad-hoc subprocess.

  When `triggered_by_event` is true, this is an event subprocess
  whose start event(s) determine when it fires.

  When `is_transaction` is true, this subprocess is a BPMN Transaction
  (`<bpmn:transaction>`). It has three possible outcomes: success (normal
  subprocess completion), cancel (Cancel End Event fires, triggers LIFO
  compensation, fires Cancel Boundary on parent), and hazard (uncaught
  error/fatal propagates without compensation).

  When `is_ad_hoc` is true, this subprocess is a BPMN Ad-hoc Subprocess
  (`<bpmn:adHocSubProcess>`). Inner activities are activated on demand
  rather than by token flow from a Start Event. Two execution models:
  engine-managed (FEEL expression determines active elements) and
  plugin-managed (`implementation` attribute delegates to plugin handler).

  `transaction_method` captures the `method` attribute of `<bpmn:transaction>`.
  No mainstream engine implements wire-level protocol integration for this
  attribute — it is preserved for BPMN fidelity but not executed.

  `in_mappings` and `out_mappings` are lists of `Mapping` structs
  where `source` is a FEEL expression and `target` is a variable name.

  `data_objects` and `data_object_references` carry data objects
  declared inside the subprocess scope. These are isolated from the
  parent process — the child PI sees only its own data objects, and
  the parent PI never sees them.
  """

  alias EvilEngine.BPMN.Model.DataObject
  alias EvilEngine.BPMN.Model.DataObjectReference
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.Mapping
  alias EvilEngine.BPMN.Model.SequenceFlow

  @type t :: %__MODULE__{
          triggered_by_event: boolean(),
          is_transaction: boolean(),
          transaction_method: String.t() | nil,
          is_ad_hoc: boolean(),
          adhoc_ordering: :parallel | :sequential,
          cancel_remaining_instances: boolean(),
          adhoc_completion_condition: String.t() | nil,
          adhoc_completion_condition_compiled: reference() | nil,
          implementation: String.t() | nil,
          active_elements_expression: String.t() | nil,
          active_elements_compiled: reference() | nil,
          flow_nodes: [FlowNode.t()],
          sequence_flows: [SequenceFlow.t()],
          in_mappings: [Mapping.t()],
          out_mappings: [Mapping.t()],
          payload_contract: map() | nil,
          result_contract: map() | nil,
          data_objects: [DataObject.t()],
          data_object_references: [DataObjectReference.t()]
        }

  defstruct triggered_by_event: false,
            is_transaction: false,
            transaction_method: nil,
            is_ad_hoc: false,
            adhoc_ordering: :parallel,
            cancel_remaining_instances: true,
            adhoc_completion_condition: nil,
            adhoc_completion_condition_compiled: nil,
            implementation: nil,
            active_elements_expression: nil,
            active_elements_compiled: nil,
            flow_nodes: [],
            sequence_flows: [],
            in_mappings: [],
            out_mappings: [],
            payload_contract: nil,
            result_contract: nil,
            data_objects: [],
            data_object_references: []
end

# ---------------------------------------------------------------------------
# FlowNodeData — Gateways
# ---------------------------------------------------------------------------

defmodule EvilEngine.BPMN.Model.FlowNodeData.ExclusiveGateway do
  @moduledoc "`<bpmn:exclusiveGateway>` — XOR split/join with optional default flow."

  @type t :: %__MODULE__{default_flow_ref: String.t() | nil}
  defstruct [:default_flow_ref]
end

defmodule EvilEngine.BPMN.Model.FlowNodeData.ParallelGateway do
  @moduledoc "`<bpmn:parallelGateway>` — AND split/join."
  @type t :: %__MODULE__{}
  defstruct []
end

defmodule EvilEngine.BPMN.Model.FlowNodeData.InclusiveGateway do
  @moduledoc "`<bpmn:inclusiveGateway>` — OR split/join with optional default flow."

  @type t :: %__MODULE__{default_flow_ref: String.t() | nil}
  defstruct [:default_flow_ref]
end

defmodule EvilEngine.BPMN.Model.FlowNodeData.EventBasedGateway do
  @moduledoc "`<bpmn:eventBasedGateway>` — first catch wins, others cancelled."
  @type t :: %__MODULE__{}
  defstruct []
end

defmodule EvilEngine.BPMN.Model.FlowNodeData.ComplexGateway do
  @moduledoc "`<bpmn:complexGateway>` with a FEEL activation condition."

  @type t :: %__MODULE__{activation_condition: String.t() | nil}
  defstruct [:activation_condition]
end

# ---------------------------------------------------------------------------
# FlowNodeData — Catch-all
# ---------------------------------------------------------------------------

defmodule EvilEngine.BPMN.Model.FlowNodeData.Unknown do
  @moduledoc "Catch-all for unrecognized BPMN elements."

  @type t :: %__MODULE__{
          element_name: String.t() | nil,
          attributes: %{String.t() => String.t()}
        }

  defstruct [:element_name, attributes: %{}]
end
