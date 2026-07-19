defmodule EvilEngine.Types.Event do
  @moduledoc """
  Namespace for every typed engine event struct.

  Each struct is one `EngineEventBus.publish/1` payload.
  Every `:telemetry.execute/3` in `core_execution` is paired with
  exactly one publish carrying one of these structs.

  Event structs are pure data — no logic, no side effects, no
  dependencies beyond `core_types`.
  """

  @type t ::
          __MODULE__.SinkFailed.t()
          | __MODULE__.EngineStarted.t()
          | __MODULE__.EngineShutdown.t()
          | __MODULE__.EngineOverloaded.t()
          | __MODULE__.EngineRecovered.t()
          | __MODULE__.PluginQuarantined.t()
          | __MODULE__.ProcessInstanceStateChanged.t()
          | __MODULE__.FlowNodeInstanceStarted.t()
          | __MODULE__.FlowNodeInstanceFinished.t()
          | __MODULE__.FlowNodeInstanceStateChanged.t()
          | __MODULE__.UserTaskCreated.t()
          | __MODULE__.UserTaskFinished.t()
          | __MODULE__.UserTaskValidationFailed.t()
          | __MODULE__.PluginAsyncFlowNodeRehydrated.t()
          | __MODULE__.CallActivityChildStarted.t()
          | __MODULE__.SubProcessChildStarted.t()
          | __MODULE__.DataObjectWritten.t()
          | __MODULE__.ProcessDefinitionDeployed.t()
          | __MODULE__.ProcessDefinitionUndeployed.t()
          | __MODULE__.ProcessDefinitionEnabled.t()
          | __MODULE__.ProcessDefinitionDisabled.t()
          | __MODULE__.DecisionDefinitionDeployed.t()
          | __MODULE__.DecisionDefinitionUndeployed.t()
          | __MODULE__.DecisionEvaluated.t()
          | __MODULE__.ProcessInstanceRetried.t()
          | __MODULE__.TimerArmed.t()
          | __MODULE__.TimerFired.t()
          | __MODULE__.TimerCancelled.t()
          | __MODULE__.MessagePublished.t()
          | __MODULE__.MessageArrived.t()
          | __MODULE__.SignalPublished.t()
          | __MODULE__.SignalArrived.t()
          | __MODULE__.EscalationRaised.t()
          | __MODULE__.CompensationTriggered.t()
          | __MODULE__.ActivityCompensated.t()
          | __MODULE__.TransactionCancelled.t()
          | __MODULE__.EventSubprocessTriggered.t()
          | __MODULE__.AdHocActivityActivated.t()
          | __MODULE__.AdHocSubProcessCompleted.t()
end

defmodule EvilEngine.Types.Event.SinkFailed do
  @moduledoc """
  Emitted by `EngineEventBus` when a sink's `handle_event/2` raises.

  Built-in sinks reject this event type by default in `accepts?/1` to
  prevent cascading failure loops.
  """

  @type t :: %__MODULE__{
          sink_name: String.t(),
          event_kind: atom(),
          reason: term(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [:sink_name, :event_kind, :reason, :occurred_at]
  defstruct [:sink_name, :event_kind, :reason, :occurred_at]
end

defmodule EvilEngine.Types.Event.EngineStarted do
  @moduledoc "Emitted once after boot completes and all sinks are wired."

  @type t :: %__MODULE__{
          engine_id: String.t(),
          engine_name: String.t(),
          version: String.t(),
          started_at: DateTime.t()
        }

  @enforce_keys [:engine_id, :started_at]
  defstruct [:engine_id, :engine_name, :version, :started_at]
end

defmodule EvilEngine.Types.Event.EngineShutdown do
  @moduledoc "Emitted during graceful shutdown before sinks are drained."

  @type t :: %__MODULE__{
          engine_id: String.t(),
          reason: atom(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [:engine_id, :reason, :occurred_at]
  defstruct [:engine_id, :reason, :occurred_at]
end

defmodule EvilEngine.Types.Event.EngineOverloaded do
  @moduledoc """
  Emitted when the engine's load level crosses a threshold.

  The poller detects threshold crossings and publishes this event
  only on transitions (e.g. normal→elevated, elevated→critical),
  not on every poll tick.
  """

  @type t :: %__MODULE__{
          level: :elevated | :critical,
          active_process_instances: non_neg_integer(),
          limit: non_neg_integer(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [:level, :active_process_instances, :limit, :occurred_at]
  defstruct [:level, :active_process_instances, :limit, :occurred_at]
end

defmodule EvilEngine.Types.Event.EngineRecovered do
  @moduledoc """
  Emitted when the engine's load level drops back to normal.

  Symmetric counterpart to `EngineOverloaded`. Published on transitions
  such as elevated→normal or critical→normal. Consumers can use this
  to release back-pressure and resume normal request rates.
  """

  @type t :: %__MODULE__{
          previous_level: :elevated | :critical,
          active_process_instances: non_neg_integer(),
          limit: non_neg_integer(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [:previous_level, :active_process_instances, :limit, :occurred_at]
  defstruct [:previous_level, :active_process_instances, :limit, :occurred_at]
end

defmodule EvilEngine.Types.Event.PluginQuarantined do
  @moduledoc "Emitted when a plugin fails discovery or `on_load`."

  @type t :: %__MODULE__{
          plugin_name: String.t(),
          tier: :inbeam | :sidecar,
          reason: String.t(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [:plugin_name, :tier, :reason, :occurred_at]
  defstruct [:plugin_name, :tier, :reason, :occurred_at]

  @doc """
  Builds a quarantine event with a user-safe `reason` string.

  Binary reasons are passed through as-is. Non-binary values (atoms, tuples,
  exceptions) are replaced with a generic message so raw Elixir terms never
  reach WebSocket consumers.
  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    plugin_name = Map.fetch!(attrs, :plugin_name)

    %__MODULE__{
      plugin_name: plugin_name,
      tier: Map.fetch!(attrs, :tier),
      reason: sanitize_reason(plugin_name, Map.fetch!(attrs, :reason)),
      occurred_at: Map.fetch!(attrs, :occurred_at)
    }
  end

  defp sanitize_reason(_plugin_name, reason) when is_binary(reason), do: reason

  defp sanitize_reason(plugin_name, _reason) do
    "Plugin '#{plugin_name}' was quarantined"
  end
end

# ---------------------------------------------------------------------------
# PI / FNI lifecycle events (Phase 1)
# ---------------------------------------------------------------------------

defmodule EvilEngine.Types.Event.ProcessInstanceStateChanged do
  @moduledoc "Emitted when a process instance transitions state."

  @type t :: %__MODULE__{
          process_instance_id: String.t(),
          process_model_id: String.t(),
          version: String.t(),
          parent_process_instance_id: String.t() | nil,
          root_process_instance_id: String.t() | nil,
          triggerer_flow_node_instance_id: String.t() | nil,
          old_state: atom() | nil,
          new_state: atom(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [:process_instance_id, :process_model_id, :version, :new_state, :occurred_at]
  defstruct [
    :process_instance_id,
    :process_model_id,
    :version,
    :parent_process_instance_id,
    :root_process_instance_id,
    :triggerer_flow_node_instance_id,
    :old_state,
    :new_state,
    :occurred_at
  ]
end

defmodule EvilEngine.Types.Event.FlowNodeInstanceStarted do
  @moduledoc """
  Emitted when a flow node instance is created and its handler begins.

  `multi_instance_id` and `iteration_index` are populated for MI/Loop
  iteration FNIs. Both are `nil` for shell FNIs and non-MI nodes.
  """

  @type t :: %__MODULE__{
          flow_node_instance_id: String.t(),
          process_instance_id: String.t(),
          root_process_instance_id: String.t() | nil,
          flow_node_id: String.t(),
          flow_node_type: atom(),
          event_type: String.t() | nil,
          lane_name: String.t() | nil,
          triggerer_flow_node_instance_id: String.t() | nil,
          multi_instance_id: String.t() | nil,
          iteration_index: non_neg_integer() | nil,
          occurred_at: DateTime.t()
        }

  @enforce_keys [
    :flow_node_instance_id,
    :process_instance_id,
    :flow_node_id,
    :flow_node_type,
    :occurred_at
  ]
  defstruct [
    :flow_node_instance_id,
    :process_instance_id,
    :root_process_instance_id,
    :flow_node_id,
    :flow_node_type,
    :event_type,
    :lane_name,
    :triggerer_flow_node_instance_id,
    :multi_instance_id,
    :iteration_index,
    :occurred_at
  ]
end

defmodule EvilEngine.Types.Event.FlowNodeInstanceFinished do
  @moduledoc """
  Emitted when a flow node instance reaches a terminal state.

  `type_properties` carries handler-specific metadata (e.g. DMN trace,
  hit policy, matched rules for Business Rule Tasks). Defaults to `%{}`
  for flow nodes that don't produce type-specific data or for non-success
  terminal states (`:fatal`, `:aborted`, `:interrupted`).

  `error_info` carries structured error details for fatal FNIs. Contains
  `error_code`, `message`, and optionally `detail`. `nil` for non-fatal
  terminal states.
  """

  @type t :: %__MODULE__{
          flow_node_instance_id: String.t(),
          process_instance_id: String.t(),
          root_process_instance_id: String.t() | nil,
          flow_node_id: String.t(),
          flow_node_type: atom(),
          event_type: String.t() | nil,
          lane_name: String.t() | nil,
          terminal_state: atom(),
          triggerer_flow_node_instance_id: String.t() | nil,
          multi_instance_id: String.t() | nil,
          iteration_index: non_neg_integer() | nil,
          type_properties: map(),
          error_info: map() | nil,
          occurred_at: DateTime.t()
        }

  @enforce_keys [
    :flow_node_instance_id,
    :process_instance_id,
    :flow_node_id,
    :flow_node_type,
    :terminal_state,
    :occurred_at
  ]

  defstruct [
    :flow_node_instance_id,
    :process_instance_id,
    :root_process_instance_id,
    :flow_node_id,
    :flow_node_type,
    :event_type,
    :lane_name,
    :terminal_state,
    :triggerer_flow_node_instance_id,
    :multi_instance_id,
    :iteration_index,
    :occurred_at,
    type_properties: %{},
    error_info: nil
  ]
end

defmodule EvilEngine.Types.Event.FlowNodeInstanceStateChanged do
  @moduledoc """
  Emitted when a flow node instance transitions between non-terminal states.

  Currently emitted for `active → waiting` transitions so the Studio
  Debugger can track FNI state without polling.
  """

  @type t :: %__MODULE__{
          flow_node_instance_id: String.t(),
          process_instance_id: String.t(),
          root_process_instance_id: String.t() | nil,
          flow_node_id: String.t(),
          flow_node_type: atom(),
          event_type: String.t() | nil,
          lane_name: String.t() | nil,
          old_state: atom(),
          new_state: atom(),
          multi_instance_id: String.t() | nil,
          iteration_index: non_neg_integer() | nil,
          occurred_at: DateTime.t()
        }

  @enforce_keys [
    :flow_node_instance_id,
    :process_instance_id,
    :flow_node_id,
    :flow_node_type,
    :old_state,
    :new_state,
    :occurred_at
  ]
  defstruct [
    :flow_node_instance_id,
    :process_instance_id,
    :root_process_instance_id,
    :flow_node_id,
    :flow_node_type,
    :event_type,
    :lane_name,
    :old_state,
    :new_state,
    :multi_instance_id,
    :iteration_index,
    :occurred_at
  ]
end

defmodule EvilEngine.Types.Event.MultiInstanceStarted do
  @moduledoc """
  Emitted when a Multi-Instance or Standard Loop shell FNI begins execution.

  `loop_type` is `"parallel_mi"`, `"sequential_mi"`, or `"standard_loop"`.
  `total_iterations` is the planned iteration count (collection length for MI,
  nil for Standard Loop where the count is determined by condition evaluation).
  """

  @type t :: %__MODULE__{
          flow_node_instance_id: String.t(),
          process_instance_id: String.t(),
          root_process_instance_id: String.t() | nil,
          flow_node_id: String.t(),
          flow_node_type: atom(),
          loop_type: String.t(),
          total_iterations: non_neg_integer() | nil,
          occurred_at: DateTime.t()
        }

  @enforce_keys [
    :flow_node_instance_id,
    :process_instance_id,
    :flow_node_id,
    :flow_node_type,
    :loop_type,
    :occurred_at
  ]
  defstruct [
    :flow_node_instance_id,
    :process_instance_id,
    :root_process_instance_id,
    :flow_node_id,
    :flow_node_type,
    :loop_type,
    :total_iterations,
    :occurred_at
  ]
end

defmodule EvilEngine.Types.Event.MultiInstanceCompleted do
  @moduledoc """
  Emitted when a Multi-Instance or Standard Loop shell FNI finishes.

  `completed_iterations` is the number of iterations that ran to completion.
  `early_break` indicates whether the loop terminated before exhausting
  all iterations (due to `completionCondition`, `loopBreakCondition`,
  `maxIterations`, or a loop condition becoming false).
  """

  @type t :: %__MODULE__{
          flow_node_instance_id: String.t(),
          process_instance_id: String.t(),
          root_process_instance_id: String.t() | nil,
          flow_node_id: String.t(),
          flow_node_type: atom(),
          loop_type: String.t(),
          total_iterations: non_neg_integer() | nil,
          completed_iterations: non_neg_integer(),
          early_break: boolean(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [
    :flow_node_instance_id,
    :process_instance_id,
    :flow_node_id,
    :flow_node_type,
    :loop_type,
    :completed_iterations,
    :early_break,
    :occurred_at
  ]
  defstruct [
    :flow_node_instance_id,
    :process_instance_id,
    :root_process_instance_id,
    :flow_node_id,
    :flow_node_type,
    :loop_type,
    :total_iterations,
    :completed_iterations,
    :early_break,
    :occurred_at
  ]
end

defmodule EvilEngine.Types.Event.UserTaskCreated do
  @moduledoc "Emitted when a User Task FNI enters `waiting` state."

  @type t :: %__MODULE__{
          flow_node_instance_id: String.t(),
          process_instance_id: String.t(),
          root_process_instance_id: String.t() | nil,
          flow_node_id: String.t(),
          assignees: [String.t()],
          occurred_at: DateTime.t()
        }

  @enforce_keys [:flow_node_instance_id, :process_instance_id, :flow_node_id, :occurred_at]
  defstruct [
    :flow_node_instance_id,
    :process_instance_id,
    :root_process_instance_id,
    :flow_node_id,
    :occurred_at,
    assignees: []
  ]
end

defmodule EvilEngine.Types.Event.UserTaskFinished do
  @moduledoc "Emitted when a User Task is completed or aborted."

  @type t :: %__MODULE__{
          flow_node_instance_id: String.t(),
          process_instance_id: String.t(),
          root_process_instance_id: String.t() | nil,
          flow_node_id: String.t(),
          outcome: :completed | :aborted,
          occurred_at: DateTime.t()
        }

  @enforce_keys [
    :flow_node_instance_id,
    :process_instance_id,
    :flow_node_id,
    :outcome,
    :occurred_at
  ]
  defstruct [
    :flow_node_instance_id,
    :process_instance_id,
    :root_process_instance_id,
    :flow_node_id,
    :outcome,
    :occurred_at
  ]
end

defmodule EvilEngine.Types.Event.UserTaskValidationFailed do
  @moduledoc "Emitted when a User Task finish attempt is rejected due to contract violation."

  @type t :: %__MODULE__{
          flow_node_instance_id: String.t(),
          process_instance_id: String.t(),
          flow_node_id: String.t(),
          violations: list(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [
    :flow_node_instance_id,
    :process_instance_id,
    :flow_node_id,
    :violations,
    :occurred_at
  ]
  defstruct [
    :flow_node_instance_id,
    :process_instance_id,
    :flow_node_id,
    :violations,
    :occurred_at
  ]
end

defmodule EvilEngine.Types.Event.PluginAsyncFlowNodeRehydrated do
  @moduledoc """
  Emitted during resume when a waiting async FNI is rehydrated.

  Signals that the FNI is back in memory. The owning plugin is expected
  to re-attach interest from its own durable state; the engine does NOT
  re-dispatch `handle_enter/3`.
  """

  @type t :: %__MODULE__{
          flow_node_instance_id: String.t(),
          process_instance_id: String.t(),
          plugin_name: String.t() | nil,
          occurred_at: DateTime.t()
        }

  @enforce_keys [:flow_node_instance_id, :process_instance_id, :occurred_at]
  defstruct [:flow_node_instance_id, :process_instance_id, :plugin_name, :occurred_at]
end

defmodule EvilEngine.Types.Event.CallActivityChildStarted do
  @moduledoc """
  Emitted by the parent PI when a Call Activity successfully spawns
  a child process instance.
  """

  @type t :: %__MODULE__{
          call_activity_flow_node_instance_id: String.t(),
          parent_process_instance_id: String.t(),
          child_process_instance_id: String.t(),
          child_process_model_id: String.t(),
          child_version: String.t(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [
    :call_activity_flow_node_instance_id,
    :parent_process_instance_id,
    :child_process_instance_id,
    :child_process_model_id,
    :child_version,
    :occurred_at
  ]

  defstruct [
    :call_activity_flow_node_instance_id,
    :parent_process_instance_id,
    :child_process_instance_id,
    :child_process_model_id,
    :child_version,
    :occurred_at
  ]
end

defmodule EvilEngine.Types.Event.SubProcessChildStarted do
  @moduledoc """
  Emitted by the parent PI when an Embedded Subprocess handler
  successfully spawns a child process instance for the inner scope.

  Mirrors `CallActivityChildStarted` but distinguishes subprocess
  children from Call Activity children in observability.
  """

  @type t :: %__MODULE__{
          subprocess_flow_node_instance_id: String.t(),
          parent_process_instance_id: String.t(),
          child_process_instance_id: String.t(),
          subprocess_node_id: String.t(),
          child_process_model_id: String.t(),
          child_version: String.t(),
          is_event_subprocess: boolean(),
          is_ad_hoc_subprocess: boolean(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [
    :subprocess_flow_node_instance_id,
    :parent_process_instance_id,
    :child_process_instance_id,
    :subprocess_node_id,
    :child_process_model_id,
    :child_version,
    :is_event_subprocess,
    :occurred_at
  ]

  defstruct [
    :subprocess_flow_node_instance_id,
    :parent_process_instance_id,
    :child_process_instance_id,
    :subprocess_node_id,
    :child_process_model_id,
    :child_version,
    :is_event_subprocess,
    :occurred_at,
    is_ad_hoc_subprocess: false
  ]
end

defmodule EvilEngine.Types.Event.EventSubprocessTriggered do
  @moduledoc """
  Emitted by the scope PI when an Event Subprocess trigger fires and spawns an
  ESP child PI (ESP-D2/D3/D4). Engine-level observability signal; the Studio
  debugger primarily uses `SubProcessChildStarted` with `is_event_subprocess`
  (ESP-D16), while this event carries the trigger kind and interrupting flag.
  """

  @type trigger_kind :: :message | :signal | :timer | :error | :escalation | :conditional

  @type t :: %__MODULE__{
          scope_process_instance_id: String.t(),
          root_process_instance_id: String.t(),
          subprocess_node_id: String.t(),
          child_process_instance_id: String.t(),
          trigger_kind: trigger_kind(),
          is_interrupting: boolean(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [
    :scope_process_instance_id,
    :root_process_instance_id,
    :subprocess_node_id,
    :child_process_instance_id,
    :trigger_kind,
    :is_interrupting,
    :occurred_at
  ]

  defstruct [
    :scope_process_instance_id,
    :root_process_instance_id,
    :subprocess_node_id,
    :child_process_instance_id,
    :trigger_kind,
    :is_interrupting,
    :occurred_at
  ]
end

defmodule EvilEngine.Types.Event.DataObjectWritten do
  @moduledoc """
  Emitted after each successful Data Object write via a DOA.

  Published from `ProcessInstance` after the DB transaction commits.
  `previous_value` is computed from the in-memory cache (not stored in
  the DB) and is useful for real-time delta consumers via WebSocket.
  """

  @type t :: %__MODULE__{
          process_instance_id: String.t(),
          root_process_instance_id: String.t() | nil,
          flow_node_instance_id: String.t(),
          data_object_id: String.t(),
          write_id: String.t(),
          previous_value: term(),
          value: term(),
          created_at: DateTime.t()
        }

  @enforce_keys [
    :process_instance_id,
    :flow_node_instance_id,
    :data_object_id,
    :write_id,
    :value,
    :created_at
  ]

  defstruct [
    :process_instance_id,
    :root_process_instance_id,
    :flow_node_instance_id,
    :data_object_id,
    :write_id,
    :previous_value,
    :value,
    :created_at
  ]
end

# ---------------------------------------------------------------------------
# BPMN process definition lifecycle events
# ---------------------------------------------------------------------------

defmodule EvilEngine.Types.Event.ProcessDefinitionDeployed do
  @moduledoc """
  Emitted when one or more BPMN process versions are deployed.

  Published per deployed version from `EvilEngine.Api.persist_deploy_batch/3`.
  The `source` field distinguishes REST-initiated deploys from plugin-initiated ones.
  """

  @type t :: %__MODULE__{
          process_model_id: String.t(),
          version: String.t(),
          source: String.t(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [:process_model_id, :version, :source, :occurred_at]
  defstruct [:process_model_id, :version, :source, :occurred_at]
end

defmodule EvilEngine.Types.Event.ProcessDefinitionUndeployed do
  @moduledoc """
  Emitted when a BPMN process version is soft-deleted.

  Published from `EvilEngine.Api.soft_delete_process_version/3`.
  The `source` field distinguishes REST-initiated deletes from plugin-initiated ones.
  """

  @type t :: %__MODULE__{
          process_model_id: String.t(),
          version: String.t() | nil,
          source: String.t(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [:process_model_id, :source, :occurred_at]
  defstruct [:process_model_id, :version, :source, :occurred_at]
end

defmodule EvilEngine.Types.Event.ProcessDefinitionEnabled do
  @moduledoc """
  Emitted when a BPMN process definition is re-enabled.

  Published from `EvilEngine.Api.update_process_enabled/3`.
  """

  @type t :: %__MODULE__{
          process_model_id: String.t(),
          source: String.t(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [:process_model_id, :source, :occurred_at]
  defstruct [:process_model_id, :source, :occurred_at]
end

defmodule EvilEngine.Types.Event.ProcessDefinitionDisabled do
  @moduledoc """
  Emitted when a BPMN process definition is disabled.

  Published from `EvilEngine.Api.update_process_enabled/3`.
  """

  @type t :: %__MODULE__{
          process_model_id: String.t(),
          source: String.t(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [:process_model_id, :source, :occurred_at]
  defstruct [:process_model_id, :source, :occurred_at]
end

# ---------------------------------------------------------------------------
# DMN lifecycle events (P8)
# ---------------------------------------------------------------------------

defmodule EvilEngine.Types.Event.DecisionDefinitionDeployed do
  @moduledoc """
  Emitted when one or more DMN decision versions are deployed.

  Published per deployed version from `EvilEngine.Api.deploy_dmn_batch/3`.
  The `source` field distinguishes REST-initiated deploys from plugin-initiated ones.
  """

  @type t :: %__MODULE__{
          decision_definition_id: String.t(),
          version: String.t(),
          source: String.t(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [:decision_definition_id, :version, :source, :occurred_at]
  defstruct [:decision_definition_id, :version, :source, :occurred_at]
end

defmodule EvilEngine.Types.Event.DecisionDefinitionUndeployed do
  @moduledoc """
  Emitted when a DMN decision version is soft-deleted.

  Published from `EvilEngine.Api.soft_delete_decision_version/3`.
  The `source` field distinguishes REST-initiated deletes from plugin-initiated ones.
  """

  @type t :: %__MODULE__{
          decision_definition_id: String.t(),
          version: String.t() | nil,
          source: String.t(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [:decision_definition_id, :source, :occurred_at]
  defstruct [:decision_definition_id, :version, :source, :occurred_at]
end

defmodule EvilEngine.Types.Event.DecisionEvaluated do
  @moduledoc """
  Emitted after a successful ad-hoc DMN evaluation via REST or plugin facade.

  Provides observability for ad-hoc evaluations (P8.5). BRT evaluations
  within a process instance are already visible through `FlowNodeInstanceFinished`
  and its `type_properties`.
  """

  @type t :: %__MODULE__{
          decision_definition_id: String.t(),
          decision_model_id: String.t() | nil,
          version: String.t() | nil,
          decision_version_id: String.t() | nil,
          duration_microseconds: non_neg_integer(),
          source: String.t(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [:decision_definition_id, :source, :occurred_at]
  defstruct [
    :decision_definition_id,
    :decision_model_id,
    :version,
    :decision_version_id,
    :duration_microseconds,
    :source,
    :occurred_at
  ]
end

# ---------------------------------------------------------------------------
# PI retry/restart events (Phase 2)
# ---------------------------------------------------------------------------

defmodule EvilEngine.Types.Event.ProcessInstanceRetried do
  @moduledoc """
  Emitted by `Execution.retry_process_instance/1` after successfully
  starting the retry gen_statem.

  `process_instance_id` is the **root** PI (where the gen_statem was
  started). `target_process_instance_id` is the PI the user actually
  targeted for retry (checkpoint/migration applied here). When the user
  retries the root PI directly, both fields are equal.
  """

  @type t :: %__MODULE__{
          process_instance_id: String.t(),
          target_process_instance_id: String.t(),
          process_model_id: String.t(),
          version: String.t(),
          previous_state: atom(),
          previous_version: String.t() | nil,
          new_version: String.t() | nil,
          reset_to_flow_node_instance_id: String.t() | nil,
          retried_by: String.t(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [
    :process_instance_id,
    :target_process_instance_id,
    :process_model_id,
    :version,
    :previous_state,
    :retried_by,
    :occurred_at
  ]
  defstruct [
    :process_instance_id,
    :target_process_instance_id,
    :process_model_id,
    :version,
    :previous_state,
    :previous_version,
    :new_version,
    :reset_to_flow_node_instance_id,
    :retried_by,
    :occurred_at
  ]
end

# ---------------------------------------------------------------------------
# Timer lifecycle events (Phase 3)
# ---------------------------------------------------------------------------

defmodule EvilEngine.Types.Event.TimerArmed do
  @moduledoc """
  Emitted by `core_execution` when a timer is registered in the Scheduler.

  Published on the EngineEventBus with full execution context. The `kind`
  field distinguishes between `:catch` (intermediate), `:boundary`, and
  `:start` timers.
  """

  @type t :: %__MODULE__{
          timer_ref: String.t(),
          process_instance_id: String.t() | nil,
          flow_node_instance_id: String.t() | nil,
          flow_node_id: String.t(),
          fire_at: DateTime.t(),
          kind: :catch | :boundary | :start,
          occurred_at: DateTime.t()
        }

  @enforce_keys [:timer_ref, :flow_node_id, :fire_at, :kind, :occurred_at]
  defstruct [
    :timer_ref,
    :process_instance_id,
    :flow_node_instance_id,
    :flow_node_id,
    :fire_at,
    :kind,
    :occurred_at
  ]
end

defmodule EvilEngine.Types.Event.TimerFired do
  @moduledoc """
  Emitted by `core_execution` when a timer fires and is processed.

  Published on the EngineEventBus after the fire message is handled
  (FNI completed, boundary caught, or PI started).
  """

  @type t :: %__MODULE__{
          timer_ref: String.t(),
          process_instance_id: String.t() | nil,
          flow_node_instance_id: String.t() | nil,
          flow_node_id: String.t(),
          kind: :catch | :boundary | :start,
          occurred_at: DateTime.t()
        }

  @enforce_keys [:timer_ref, :flow_node_id, :kind, :occurred_at]
  defstruct [
    :timer_ref,
    :process_instance_id,
    :flow_node_instance_id,
    :flow_node_id,
    :kind,
    :occurred_at
  ]
end

defmodule EvilEngine.Types.Event.TimerCancelled do
  @moduledoc """
  Emitted by `core_execution` when a timer is cancelled.

  Typical reasons: host activity completed before the boundary timer
  fired, PI terminated, or a schedule was disabled via the REST API.
  """

  @type t :: %__MODULE__{
          timer_ref: String.t(),
          process_instance_id: String.t() | nil,
          flow_node_instance_id: String.t() | nil,
          reason: String.t(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [:timer_ref, :reason, :occurred_at]
  defstruct [
    :timer_ref,
    :process_instance_id,
    :flow_node_instance_id,
    :reason,
    :occurred_at
  ]
end

# ---------------------------------------------------------------------------
# Message lifecycle events (Phase 3)
# ---------------------------------------------------------------------------

defmodule EvilEngine.Types.Event.MessagePublished do
  @moduledoc """
  Emitted by `MessagePublisher` after a message is published through the
  correlation algorithm.

  Captures the full publish outcome: how many subscriptions received the
  message, whether new PIs were started via Message Start Events, and
  whether the message was buffered as pending.
  """

  @type t :: %__MODULE__{
          message_id: String.t(),
          message_name: String.t(),
          correlation_value: String.t() | nil,
          origin: map(),
          deliveries: [%{process_instance_id: String.t(), flow_node_instance_id: String.t()}],
          started_process_instance_ids: [String.t()],
          pending: boolean(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [:message_id, :message_name, :occurred_at]
  defstruct [
    :message_id,
    :message_name,
    :correlation_value,
    :origin,
    :occurred_at,
    deliveries: [],
    started_process_instance_ids: [],
    pending: false
  ]
end

defmodule EvilEngine.Types.Event.MessageArrived do
  @moduledoc """
  Emitted when a message is delivered to a specific waiting FNI.

  Published per-delivery from `MessagePublisher` after the message
  payload is sent to the handler Task's mailbox.
  """

  @type t :: %__MODULE__{
          message_id: String.t(),
          message_name: String.t(),
          correlation_value: String.t() | nil,
          process_instance_id: String.t(),
          flow_node_instance_id: String.t(),
          payload: map(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [
    :message_id,
    :message_name,
    :process_instance_id,
    :flow_node_instance_id,
    :occurred_at
  ]

  defstruct [
    :message_id,
    :message_name,
    :correlation_value,
    :process_instance_id,
    :flow_node_instance_id,
    :occurred_at,
    payload: %{}
  ]
end

# ---------------------------------------------------------------------------
# Signal lifecycle events (Phase 3)
# ---------------------------------------------------------------------------

defmodule EvilEngine.Types.Event.SignalPublished do
  @moduledoc """
  Emitted by `SignalPublisher` after a signal is broadcast.

  Captures the full broadcast outcome: how many subscriptions received
  the signal, whether new PIs were started via Signal Start Events, and
  whether the signal was buffered as pending (zero-match case).

  Signals carry no payload and use no correlation — they are pure
  broadcast by signal name.
  """

  @type t :: %__MODULE__{
          signal_id: String.t(),
          signal_name: String.t(),
          origin: map(),
          deliveries: [%{process_instance_id: String.t(), flow_node_instance_id: String.t()}],
          started_process_instance_ids: [String.t()],
          pending: boolean(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [:signal_id, :signal_name, :occurred_at]
  defstruct [
    :signal_id,
    :signal_name,
    :origin,
    :occurred_at,
    deliveries: [],
    started_process_instance_ids: [],
    pending: false
  ]
end

defmodule EvilEngine.Types.Event.SignalArrived do
  @moduledoc """
  Emitted when a signal is delivered to a specific waiting FNI.

  Published per-delivery from `SignalPublisher` after the signal
  notification is sent to the handler Task's mailbox. Signals carry
  no payload — only the signal identity and recipient are recorded.
  """

  @type t :: %__MODULE__{
          signal_id: String.t(),
          signal_name: String.t(),
          process_instance_id: String.t(),
          flow_node_instance_id: String.t(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [
    :signal_id,
    :signal_name,
    :process_instance_id,
    :flow_node_instance_id,
    :occurred_at
  ]

  defstruct [
    :signal_id,
    :signal_name,
    :process_instance_id,
    :flow_node_instance_id,
    :occurred_at
  ]
end

# ---------------------------------------------------------------------------
# Escalation lifecycle events (Phase 4)
# ---------------------------------------------------------------------------

defmodule EvilEngine.Types.Event.EscalationRaised do
  @moduledoc """
  Emitted when an Escalation is raised by an Escalation End Event or an
  Escalation Intermediate Throw Event.

  Published from the PI state machine immediately when the throw FNI is
  processed. The `throw_type` field distinguishes terminal escalations
  (`:end_event`) from pass-through ones (`:intermediate_throw`).

  This event is always emitted on throw — regardless of whether the
  escalation is eventually caught by a boundary event in an ancestor scope.
  """

  @type throw_type :: :end_event | :intermediate_throw

  @type t :: %__MODULE__{
          escalation_code: String.t() | nil,
          escalation_name: String.t() | nil,
          process_instance_id: String.t(),
          root_process_instance_id: String.t() | nil,
          flow_node_instance_id: String.t(),
          flow_node_id: String.t(),
          throw_type: throw_type(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [
    :process_instance_id,
    :flow_node_instance_id,
    :flow_node_id,
    :throw_type,
    :occurred_at
  ]

  defstruct [
    :escalation_code,
    :escalation_name,
    :process_instance_id,
    :root_process_instance_id,
    :flow_node_instance_id,
    :flow_node_id,
    :throw_type,
    :occurred_at
  ]
end

defmodule EvilEngine.Types.Event.CompensationTriggered do
  @moduledoc """
  Emitted when a Compensate Throw or Compensate End Event fires,
  before any compensation handler activities are dispatched.

  `throw_type` distinguishes `:throw` (intermediate, flow continues
  after handlers) from `:end` (token consumed, PI may reach
  `:compensated`). `target_count` is the number of handler activities
  that will be dispatched (may be 0 if no completed activities have
  compensation handlers).
  """

  @type throw_type :: :throw | :end

  @type t :: %__MODULE__{
          process_instance_id: String.t(),
          root_process_instance_id: String.t() | nil,
          flow_node_instance_id: String.t(),
          flow_node_id: String.t(),
          throw_type: throw_type(),
          activity_ref: String.t() | nil,
          target_count: non_neg_integer(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [
    :process_instance_id,
    :flow_node_instance_id,
    :flow_node_id,
    :throw_type,
    :target_count,
    :occurred_at
  ]

  defstruct [
    :process_instance_id,
    :root_process_instance_id,
    :flow_node_instance_id,
    :flow_node_id,
    :throw_type,
    :activity_ref,
    :target_count,
    :occurred_at
  ]
end

defmodule EvilEngine.Types.Event.TransactionCancelled do
  @moduledoc """
  Emitted when a Transaction subprocess child PI transitions to `:cancelled`.

  Fires after any automatic compensation run triggered by the Cancel End
  Event has completed (or immediately if no compensable activities existed).

  `transaction_node_id` is the BPMN element ID of the `<bpmn:transaction>`
  subprocess shell in the parent process. `compensation_handler_count` is
  the number of completed activities that had registered compensation
  handlers; it may be 0 if the transaction had no compensable activities.

  This event is broadcast to both `process_instance:<process_instance_id>`
  and `process_instance:<root_process_instance_id>` channels.
  """

  @type t :: %__MODULE__{
          process_instance_id: String.t(),
          root_process_instance_id: String.t() | nil,
          transaction_node_id: String.t() | nil,
          compensation_handler_count: non_neg_integer(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [
    :process_instance_id,
    :compensation_handler_count,
    :occurred_at
  ]

  defstruct [
    :process_instance_id,
    :root_process_instance_id,
    :transaction_node_id,
    :compensation_handler_count,
    :occurred_at
  ]
end

# ---------------------------------------------------------------------------
# Ad-hoc subprocess events
# ---------------------------------------------------------------------------

defmodule EvilEngine.Types.Event.AdHocActivityActivated do
  @moduledoc "Emitted when an inner activity within an ad-hoc subprocess is activated."

  @type t :: %__MODULE__{
          process_instance_id: String.t(),
          root_process_instance_id: String.t(),
          adhoc_flow_node_instance_id: String.t(),
          activated_flow_node_id: String.t(),
          activated_flow_node_instance_id: String.t(),
          activation_source: String.t(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [
    :process_instance_id,
    :root_process_instance_id,
    :adhoc_flow_node_instance_id,
    :activated_flow_node_id,
    :activated_flow_node_instance_id,
    :activation_source,
    :occurred_at
  ]

  defstruct [
    :process_instance_id,
    :root_process_instance_id,
    :adhoc_flow_node_instance_id,
    :activated_flow_node_id,
    :activated_flow_node_instance_id,
    :activation_source,
    :occurred_at
  ]
end

defmodule EvilEngine.Types.Event.AdHocSubProcessCompleted do
  @moduledoc "Emitted when an ad-hoc subprocess finishes execution."

  @type t :: %__MODULE__{
          process_instance_id: String.t(),
          root_process_instance_id: String.t(),
          adhoc_flow_node_instance_id: String.t(),
          adhoc_node_id: String.t(),
          completion_reason: atom() | String.t(),
          total_activations: non_neg_integer(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [
    :process_instance_id,
    :root_process_instance_id,
    :adhoc_flow_node_instance_id,
    :adhoc_node_id,
    :completion_reason,
    :total_activations,
    :occurred_at
  ]

  defstruct [
    :process_instance_id,
    :root_process_instance_id,
    :adhoc_flow_node_instance_id,
    :adhoc_node_id,
    :completion_reason,
    :total_activations,
    :occurred_at
  ]
end

defmodule EvilEngine.Types.Event.ActivityCompensated do
  @moduledoc """
  Emitted after each compensation handler activity finishes successfully.

  `compensated_fni_id` identifies the original completed FNI whose work
  was undone; `handler_fni_id` identifies the compensation handler FNI
  that executed; `throw_fni_id` identifies the Compensate Throw/End FNI
  that initiated the compensation run.
  """

  @type t :: %__MODULE__{
          process_instance_id: String.t(),
          root_process_instance_id: String.t() | nil,
          compensated_fni_id: String.t(),
          handler_fni_id: String.t(),
          throw_fni_id: String.t(),
          flow_node_id: String.t(),
          handler_activity_id: String.t(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [
    :process_instance_id,
    :compensated_fni_id,
    :handler_fni_id,
    :throw_fni_id,
    :flow_node_id,
    :handler_activity_id,
    :occurred_at
  ]

  defstruct [
    :process_instance_id,
    :root_process_instance_id,
    :compensated_fni_id,
    :handler_fni_id,
    :throw_fni_id,
    :flow_node_id,
    :handler_activity_id,
    :occurred_at
  ]
end
