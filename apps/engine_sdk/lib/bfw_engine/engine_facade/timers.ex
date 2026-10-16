defmodule BfwEngine.EngineFacade.Timers do
  @moduledoc """
  Runtime namespace for timer event trigger and cycle-schedule management.

  Closures are wired by the Loader to `BfwEngine.Api` with the plugin's
  synthetic identity pre-injected (`skip_claims: true`).

  `trigger_event` answers `{:ok, %{triggered: true}}` when a timer fired and
  `{:ok, %{triggered: false}}` when nothing was armed, like REST
  `POST /timer-events/{id}/trigger`; not found, forbidden, not a timer
  event, and not waiting are `{:error, reason}`.
  """

  @type t :: %__MODULE__{
          trigger_event: (String.t() -> {:ok, %{triggered: boolean()}} | {:error, term()}),
          list_schedules: (keyword() -> {:ok, list()} | {:error, term()}),
          get_schedule: (String.t() -> {:ok, map()} | {:error, term()}),
          enable_schedule: (String.t() -> {:ok, map()} | {:error, term()}),
          disable_schedule: (String.t() -> {:ok, map()} | {:error, term()})
        }

  defstruct trigger_event: &__MODULE__.noop_1/1,
            list_schedules: &__MODULE__.noop_1/1,
            get_schedule: &__MODULE__.noop_1/1,
            enable_schedule: &__MODULE__.noop_1/1,
            disable_schedule: &__MODULE__.noop_1/1

  # Default capture for this module's struct fields.
  @doc false
  @spec noop_1(term()) :: {:error, :not_wired}
  def noop_1(_arg), do: {:error, :not_wired}
end
