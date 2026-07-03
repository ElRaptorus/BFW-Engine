# ---------------------------------------------------------------------------
# EventDefinition structs — trigger-specific data nested inside event
# FlowNodeData via the `event_definition` field.
# ---------------------------------------------------------------------------

defmodule EvilEngine.BPMN.Model.EventDefinition.None do
  @moduledoc "Empty event definition for plain/untyped start and end events."
  @type t :: %__MODULE__{}
  defstruct []
end

defmodule EvilEngine.BPMN.Model.EventDefinition.Message do
  @moduledoc """
  Message event definition — carries correlation, payload expression, and
  event mapping fields from `evil:*` extensions alongside the BPMN `messageRef`.

  Data contracts (`payloadContract` / `resultContract`) are **not** stored here.
  They live on the event position struct: throw-side events get
  `payload_contract`, catch-side events get `result_contract`.
  """

  @type t :: %__MODULE__{
          message_ref: String.t() | nil,
          correlation_retrieval_expression: String.t() | nil,
          payload_expression: String.t() | nil,
          event_mapping: String.t() | nil
        }

  defstruct [
    :message_ref,
    :correlation_retrieval_expression,
    :payload_expression,
    :event_mapping
  ]
end

defmodule EvilEngine.BPMN.Model.EventDefinition.Signal do
  @moduledoc "Signal event definition. Signals are broadcast with no correlation."

  @type t :: %__MODULE__{signal_ref: String.t() | nil}
  defstruct [:signal_ref]
end

defmodule EvilEngine.BPMN.Model.EventDefinition.Timer do
  @moduledoc """
  Timer event definition. Exactly one of the three ISO 8601 fields
  should be set: `time_date`, `time_duration`, or `time_cycle`.
  """

  @type t :: %__MODULE__{
          time_date: String.t() | nil,
          time_duration: String.t() | nil,
          time_cycle: String.t() | nil
        }

  defstruct [:time_date, :time_duration, :time_cycle]
end

defmodule EvilEngine.BPMN.Model.EventDefinition.Error do
  @moduledoc """
  Error event definition. When both `error_code` and `error_message`
  are present on a boundary event, matching semantics are AND.
  """

  @type t :: %__MODULE__{
          error_ref: String.t() | nil,
          error_code: String.t() | nil,
          error_message: String.t() | nil
        }

  defstruct [:error_ref, :error_code, :error_message]
end

defmodule EvilEngine.BPMN.Model.EventDefinition.Escalation do
  @moduledoc "Escalation event definition. Boundary matching is by escalation code."

  @type t :: %__MODULE__{
          escalation_ref: String.t() | nil,
          escalation_code: String.t() | nil
        }

  defstruct [:escalation_ref, :escalation_code]
end

defmodule EvilEngine.BPMN.Model.EventDefinition.Conditional do
  @moduledoc "Conditional event definition. FEEL expression evaluated against PI state."

  @type t :: %__MODULE__{condition_expression: String.t() | nil}
  defstruct [:condition_expression]
end

defmodule EvilEngine.BPMN.Model.EventDefinition.Compensation do
  @moduledoc """
  Compensation event definition.
  `activity_ref` targets a single activity; nil means "all".
  """

  @type t :: %__MODULE__{
          activity_ref: String.t() | nil,
          wait_for_completion: boolean()
        }

  defstruct [:activity_ref, wait_for_completion: true]
end

defmodule EvilEngine.BPMN.Model.EventDefinition.Terminate do
  @moduledoc "Terminate event definition. Semantics are position-dependent."
  @type t :: %__MODULE__{}
  defstruct []
end

defmodule EvilEngine.BPMN.Model.EventDefinition.Cancel do
  @moduledoc "Cancel event definition. Only valid inside transaction subprocesses."
  @type t :: %__MODULE__{}
  defstruct []
end

defmodule EvilEngine.BPMN.Model.EventDefinition.Link do
  @moduledoc "Link event definition. Throw links to matching catch within same process."

  @type t :: %__MODULE__{link_name: String.t() | nil}
  defstruct [:link_name]
end

# ---------------------------------------------------------------------------
# FlowNodeData event position structs — carry a typed `event_definition`.
# ---------------------------------------------------------------------------

defmodule EvilEngine.BPMN.Model.FlowNodeData.StartEvent do
  @moduledoc """
  Start event position data. `event_definition` is one of
  `EventDefinition.None`, `.Message`, `.Signal`, `.Timer`, `.Conditional`,
  `.Error`, `.Escalation`.

  `result_contract` validates incoming data on catch-side events
  (message start events receive messages).

  `is_interrupting` is only meaningful for Event Subprocess start events
  (BPMN `isInterrupting`, default `true`). It is ignored for top-level and
  embedded-subprocess start events (which are always "interrupting" in the
  trivial sense of being the sole entry point).
  """

  alias EvilEngine.BPMN.Model.EventDefinition

  @type event_def ::
          EventDefinition.None.t()
          | EventDefinition.Message.t()
          | EventDefinition.Signal.t()
          | EventDefinition.Timer.t()
          | EventDefinition.Conditional.t()
          | EventDefinition.Error.t()
          | EventDefinition.Escalation.t()

  @type t :: %__MODULE__{
          event_definition: event_def(),
          result_contract: map() | nil,
          is_interrupting: boolean()
        }
  defstruct event_definition: %EventDefinition.None{},
            result_contract: nil,
            is_interrupting: true
end

defmodule EvilEngine.BPMN.Model.FlowNodeData.EndEvent do
  @moduledoc """
  End event position data. `event_definition` is one of
  `EventDefinition.None`, `.Message`, `.Signal`, `.Error`,
  `.Escalation`, `.Terminate`, `.Cancel`, `.Compensation`.

  `in_mappings` are populated for message end events.
  """

  alias EvilEngine.BPMN.Model.{EventDefinition, Mapping}

  @type event_def ::
          EventDefinition.None.t()
          | EventDefinition.Message.t()
          | EventDefinition.Signal.t()
          | EventDefinition.Error.t()
          | EventDefinition.Escalation.t()
          | EventDefinition.Terminate.t()
          | EventDefinition.Cancel.t()
          | EventDefinition.Compensation.t()

  @type t :: %__MODULE__{
          event_definition: event_def(),
          in_mappings: [Mapping.t()],
          payload_contract: map() | nil
        }
  defstruct event_definition: %EventDefinition.None{}, in_mappings: [], payload_contract: nil
end

defmodule EvilEngine.BPMN.Model.FlowNodeData.IntermediateCatchEvent do
  @moduledoc """
  Intermediate catch event position data. `event_definition` is one of
  `EventDefinition.Message`, `.Signal`, `.Timer`, `.Conditional`, `.Link`.

  `out_mappings` are populated for message catch events.
  """

  alias EvilEngine.BPMN.Model.{EventDefinition, Mapping}

  @type event_def ::
          EventDefinition.Message.t()
          | EventDefinition.Signal.t()
          | EventDefinition.Timer.t()
          | EventDefinition.Conditional.t()
          | EventDefinition.Link.t()

  @type t :: %__MODULE__{
          event_definition: event_def(),
          out_mappings: [Mapping.t()],
          result_contract: map() | nil
        }
  defstruct event_definition: %EventDefinition.None{}, out_mappings: [], result_contract: nil
end

defmodule EvilEngine.BPMN.Model.FlowNodeData.IntermediateThrowEvent do
  @moduledoc """
  Intermediate throw event position data. `event_definition` is one of
  `EventDefinition.Message`, `.Signal`, `.Escalation`, `.Compensation`, `.Link`.

  `in_mappings` are populated for message throw events.
  """

  alias EvilEngine.BPMN.Model.{EventDefinition, Mapping}

  @type event_def ::
          EventDefinition.Message.t()
          | EventDefinition.Signal.t()
          | EventDefinition.Escalation.t()
          | EventDefinition.Compensation.t()
          | EventDefinition.Link.t()

  @type t :: %__MODULE__{
          event_definition: event_def(),
          in_mappings: [Mapping.t()],
          payload_contract: map() | nil
        }
  defstruct event_definition: %EventDefinition.None{}, in_mappings: [], payload_contract: nil
end

defmodule EvilEngine.BPMN.Model.FlowNodeData.BoundaryEvent do
  @moduledoc """
  Boundary event position data. Attached to a host activity.

  `cancel_activity` = true means interrupting, false = non-interrupting.
  `out_mappings` are populated for message boundary events.
  """

  alias EvilEngine.BPMN.Model.{EventDefinition, Mapping}

  @type event_def ::
          EventDefinition.Message.t()
          | EventDefinition.Signal.t()
          | EventDefinition.Error.t()
          | EventDefinition.Timer.t()
          | EventDefinition.Escalation.t()
          | EventDefinition.Conditional.t()
          | EventDefinition.Compensation.t()
          | EventDefinition.Cancel.t()

  @type t :: %__MODULE__{
          event_definition: event_def(),
          attached_to_ref: String.t() | nil,
          cancel_activity: boolean(),
          out_mappings: [Mapping.t()],
          result_contract: map() | nil
        }

  defstruct event_definition: %EventDefinition.None{},
            attached_to_ref: nil,
            cancel_activity: true,
            out_mappings: [],
            result_contract: nil
end
