defmodule EvilEngine.EngineFacade.AdhocSubprocesses do
  @moduledoc """
  Runtime namespace for ad-hoc subprocess control.

  Provides closures for querying, activating inner activities, and
  completing ad-hoc subprocesses. The `Loader` wires each closure to
  the corresponding `EvilEngine.Api` function with the plugin's
  synthetic identity pre-injected.
  """

  @type t :: %__MODULE__{
          get_enabled_activities: (String.t() -> {:ok, [map()]} | {:error, term()}),
          activate_activity: (String.t(), String.t() -> {:ok, map()} | {:error, term()}),
          complete: (String.t() -> :ok | {:error, term()}),
          get_status: (String.t() -> {:ok, map()} | {:error, term()})
        }

  defstruct get_enabled_activities: &__MODULE__.noop_1/1,
            activate_activity: &__MODULE__.noop_2/2,
            complete: &__MODULE__.noop_1/1,
            get_status: &__MODULE__.noop_1/1

  @doc false
  @spec noop_1(term()) :: {:error, :not_wired}
  def noop_1(_arg), do: {:error, :not_wired}

  @doc false
  @spec noop_2(term(), term()) :: {:error, :not_wired}
  def noop_2(_arg1, _arg2), do: {:error, :not_wired}
end
