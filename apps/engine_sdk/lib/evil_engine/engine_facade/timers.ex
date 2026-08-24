defmodule EvilEngine.EngineFacade.Timers do
  @moduledoc """
  Runtime namespace for timer event trigger and cycle-schedule management.

  Closures are wired by the Loader to `EvilEngine.Api` with the plugin's
  synthetic identity pre-injected (`skip_claims: true`).
  """

  @type t :: %__MODULE__{
          trigger_event: (String.t() -> :ok | {:error, term()}),
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

  @doc false
  @spec noop_1(term()) :: {:error, :not_wired}
  def noop_1(_arg), do: {:error, :not_wired}
end
