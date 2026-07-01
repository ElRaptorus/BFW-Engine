defmodule EvilEngine.BPMN.Model.Definitions do
  @moduledoc """
  Root container for a parsed BPMN XML document.

  Holds the list of `Process` structs, global BPMN object definitions
  (messages, signals, errors, escalations), and the original XML source.
  """

  alias EvilEngine.BPMN.Model.ErrorDefinition
  alias EvilEngine.BPMN.Model.EscalationDefinition
  alias EvilEngine.BPMN.Model.MessageDefinition
  alias EvilEngine.BPMN.Model.Process
  alias EvilEngine.BPMN.Model.SignalDefinition

  @type t :: %__MODULE__{
          definitions_id: String.t() | nil,
          processes: [Process.t()],
          messages: [MessageDefinition.t()],
          signals: [SignalDefinition.t()],
          errors: [ErrorDefinition.t()],
          escalations: [EscalationDefinition.t()],
          raw_xml: String.t()
        }

  @enforce_keys [:raw_xml]
  defstruct definitions_id: nil,
            processes: [],
            messages: [],
            signals: [],
            errors: [],
            escalations: [],
            raw_xml: ""
end

defmodule EvilEngine.BPMN.Model.MessageDefinition do
  @moduledoc """
  Global `<bpmn:message>` element declared at the definitions level.

  Referenced by `EventDefinition.Message.message_ref`,
  `FlowNodeData.SendTask.message_ref`, and
  `FlowNodeData.ReceiveTask.message_ref`.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil
        }

  @enforce_keys [:id]
  defstruct [:id, :name]
end

defmodule EvilEngine.BPMN.Model.SignalDefinition do
  @moduledoc """
  Global `<bpmn:signal>` element declared at the definitions level.

  Referenced by `EventDefinition.Signal.signal_ref`.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil
        }

  @enforce_keys [:id]
  defstruct [:id, :name]
end

defmodule EvilEngine.BPMN.Model.ErrorDefinition do
  @moduledoc """
  Global `<bpmn:error>` element declared at the definitions level.

  Referenced by `EventDefinition.Error.error_ref`.
  `error_code` comes from the `errorCode` XML attribute.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          error_code: String.t() | nil
        }

  @enforce_keys [:id]
  defstruct [:id, :name, :error_code]
end

defmodule EvilEngine.BPMN.Model.EscalationDefinition do
  @moduledoc """
  Global `<bpmn:escalation>` element declared at the definitions level.

  Referenced by `EventDefinition.Escalation.escalation_ref`.
  `escalation_code` comes from the `escalationCode` XML attribute.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          escalation_code: String.t() | nil
        }

  @enforce_keys [:id]
  defstruct [:id, :name, :escalation_code]
end
