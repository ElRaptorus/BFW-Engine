defmodule EvilEngine.Timers.Persistence do
  @moduledoc """
  Behaviour defining persistence operations for Timer Start schedules.

  Only Timer Start Events use this behaviour. PI-scoped timers
  (Intermediate Catch and Boundary) are stored in FNI `type_properties`
  and do not need a dedicated persistence layer.

  The real implementation lives in `peripheral_persistence`
  (`EvilEngine.Persistence.TimerStartScheduleAdapter`). For unit tests,
  `EvilEngine.Timers.Persistence.NoOp` provides an in-memory stub.
  """

  @type schedule_attrs :: %{
          optional(:id) => String.t(),
          optional(:process_version_id) => String.t(),
          optional(:process_model_id) => String.t(),
          optional(:flow_node_id) => String.t(),
          optional(:kind) => String.t(),
          optional(:iso_spec) => String.t(),
          optional(:enabled) => boolean(),
          optional(:next_fire_at) => DateTime.t() | nil,
          optional(:last_triggered_at) => DateTime.t() | nil,
          optional(:cycle_total) => non_neg_integer() | nil,
          optional(:cycle_remaining) => non_neg_integer() | nil,
          optional(:scheduler_ref) => String.t() | nil
        }

  @type schedule_record :: %{
          id: String.t(),
          process_version_id: String.t(),
          process_model_id: String.t(),
          flow_node_id: String.t(),
          kind: String.t(),
          iso_spec: String.t(),
          enabled: boolean(),
          next_fire_at: DateTime.t() | nil,
          last_triggered_at: DateTime.t() | nil,
          cycle_total: non_neg_integer() | nil,
          cycle_remaining: non_neg_integer() | nil,
          scheduler_ref: String.t() | nil
        }

  @callback create_schedule(attrs :: schedule_attrs()) ::
              {:ok, schedule_record()} | {:error, term()}
  @callback update_schedule(id :: String.t(), changes :: map()) ::
              {:ok, schedule_record()} | {:error, term()}
  @callback delete_schedules_for_version(process_version_id :: String.t()) :: :ok
  @callback list_armed_schedules() :: {:ok, [schedule_record()]}
  @callback list_all_schedules(opts :: keyword()) :: {:ok, [schedule_record()]}
  @callback get_schedule(id :: String.t()) :: {:ok, schedule_record()} | {:error, :not_found}
end
