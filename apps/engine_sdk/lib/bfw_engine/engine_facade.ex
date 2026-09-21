defmodule BfwEngine.EngineFacade do
  @moduledoc """
  Struct passed to every plugin's `on_load/1` and `on_ready/1` callbacks.

  Provides a stable, read-only surface that lets plugins discover engine
  identity, register capabilities, publish events, read configuration,
  and interact with runtime resources — all without reaching into
  internal GenServers. The engine constructs this struct once during
  boot and shares it (immutably) with every plugin.

  ## Fields

  ### Identity (read-only)

  | Field | Type | Description |
  |-------|------|-------------|
  | `engine_id` | `String.t()` | Value of `BFE_ENGINE_ID` |
  | `engine_name` | `String.t()` | Value of `BFE_ENGINE_NAME` |
  | `version` | `String.t()` | Release version string |

  ### Capability Registration

  Each function registers a specific capability type in the Plugin Registry.
  All return `registration_result()`.

  | Field | Signature | Description |
  |-------|-----------|-------------|
  | `register_service_task_handler` | `(implementation, handler_module)` | Registers a Service Task handler keyed by implementation string |
  | `register_named_script` | `(script_key, handler_module)` | Registers a Named Script handler keyed by script key |
  | `register_rest_api_extension` | `(prefix, handler_module)` | Registers a REST API extension keyed by URL prefix |
  | `register_auth_provider` | `(handler_module)` | Registers an Auth Provider (unique, first wins) |
  | `register_event_sink` | `(name, module, opts)` | Registers an EventSink with the EngineEventBus |

  ### Infrastructure

  | Field | Signature | Description |
  |-------|-----------|-------------|
  | `publish_event` | `(Event.t()) -> :ok` | Publishes a typed event to the EngineEventBus |
  | `get_config` | `(atom()) -> term()` | Reads a runtime configuration key |

  ### Resource-Scoped Runtime Namespaces

  | Field | Type | Description |
  |-------|------|-------------|
  | `processes` | `EngineFacade.Processes.t()` | Catalog reads + writes for Process Models / Versions |
  | `process_instances` | `EngineFacade.ProcessInstances.t()` | Runtime commands on Process Instances |
  | `user_tasks` | `EngineFacade.UserTasks.t()` | User Task finish / cancel |
  | `service_tasks` | `EngineFacade.ServiceTasks.t()` | Async Service Task complete / fail |
  | `flow_node_instances` | `EngineFacade.FlowNodeInstances.t()` | FNI reads |
  | `data_objects` | `EngineFacade.DataObjects.t()` | Data Object reads + history |
  | `decisions` | `EngineFacade.Decisions.t()` | Decision Model catalog reads + writes + evaluation |
  | `messages` | `EngineFacade.Messages.t()` | Message publish (`publish/3`) |
  | `signals` | `EngineFacade.Signals.t()` | Signal broadcast publish (`publish/1`; no payload, no correlation) |
  | `escalations` | `EngineFacade.Escalations.t()` | Escalation inject (`publish/1`; waiter delivery, no payload) |
  | `adhoc_subprocesses` | `EngineFacade.AdhocSubprocesses.t()` | Ad-hoc subprocess control (activate, complete, status) |
  | `timers` | `EngineFacade.Timers.t()` | Timer event trigger + cycle schedule list/enable/disable |
  | `graphql` | `EngineFacade.Graphql.t()` | Raw GraphQL query execution |
  """

  alias __MODULE__.{
    AdhocSubprocesses,
    DataObjects,
    Decisions,
    Escalations,
    FlowNodeInstances,
    Graphql,
    Messages,
    ProcessInstances,
    Processes,
    ServiceTasks,
    Signals,
    Timers,
    UserTasks
  }

  @typedoc "Handler module atom. Non-atom descriptors skip behaviour validation."
  @type handler_module :: module() | String.t()

  @typedoc "Return type shared by all capability registration functions."
  @type registration_result ::
          :ok
          | {:error, :conflict, String.t()}
          | {:error, :invalid_handler, String.t()}
          | {:error, :module_not_loaded, String.t()}
          | {:error, :reserved_prefix}
          | {:error, :not_wired}
          | {:error, :not_implemented}

  @type t :: %__MODULE__{
          engine_id: String.t(),
          engine_name: String.t(),
          version: String.t(),
          register_service_task_handler: (String.t(), handler_module() -> registration_result()),
          register_named_script: (String.t(), handler_module() -> registration_result()),
          register_rest_api_extension: (String.t(), handler_module() -> registration_result()),
          register_auth_provider: (handler_module() -> registration_result()),
          register_event_sink: (String.t(), module(), keyword() -> :ok | {:error, term()}),
          publish_event: (struct() -> :ok),
          get_config: (atom() -> term()),
          processes: Processes.t(),
          process_instances: ProcessInstances.t(),
          user_tasks: UserTasks.t(),
          service_tasks: ServiceTasks.t(),
          flow_node_instances: FlowNodeInstances.t(),
          data_objects: DataObjects.t(),
          decisions: Decisions.t(),
          messages: Messages.t(),
          signals: Signals.t(),
          escalations: Escalations.t(),
          adhoc_subprocesses: AdhocSubprocesses.t(),
          timers: Timers.t(),
          graphql: Graphql.t()
        }

  @enforce_keys [:engine_id, :engine_name, :version]
  defstruct [
    :engine_id,
    :engine_name,
    :version,
    register_service_task_handler: &__MODULE__.noop_register_2/2,
    register_named_script: &__MODULE__.noop_register_2/2,
    register_rest_api_extension: &__MODULE__.noop_register_2/2,
    register_auth_provider: &__MODULE__.noop_register_1/1,
    register_event_sink: &__MODULE__.noop_register_event_sink/3,
    publish_event: &__MODULE__.noop_publish_event/1,
    get_config: &__MODULE__.noop_get_config/1,
    processes: %Processes{},
    process_instances: %ProcessInstances{},
    user_tasks: %UserTasks{},
    service_tasks: %ServiceTasks{},
    flow_node_instances: %FlowNodeInstances{},
    data_objects: %DataObjects{},
    decisions: %Decisions{},
    messages: %Messages{},
    signals: %Signals{},
    escalations: %Escalations{},
    adhoc_subprocesses: %AdhocSubprocesses{},
    timers: %Timers{},
    graphql: %Graphql{}
  ]

  @doc false
  def noop_register_2(_key, _handler), do: {:error, :not_wired}
  @doc false
  def noop_register_1(_handler), do: {:error, :not_wired}
  @doc false
  def noop_publish_event(_event), do: :ok
  @doc false
  def noop_register_event_sink(_name, _mod, _opts), do: {:error, :not_wired}
  @doc false
  def noop_get_config(_key), do: nil
end
