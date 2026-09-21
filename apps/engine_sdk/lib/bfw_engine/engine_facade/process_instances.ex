defmodule BfwEngine.EngineFacade.ProcessInstances do
  @moduledoc """
  Runtime namespace for Process Instance commands.

  Provides typed closures for reading, aborting, retrying, and
  soft-deleting process instances. The `Loader` wires each closure
  to the corresponding `BfwEngine.Api` function with the plugin's
  synthetic identity pre-injected.
  """

  @type t :: %__MODULE__{
          get: (String.t() -> {:ok, struct()} | {:error, term()}),
          abort: (String.t(), String.t() | nil -> :ok | {:error, term()}),
          retry: (String.t(), map() -> :ok | {:error, term()}),
          delete: (String.t() -> {:ok, struct()} | {:error, term()})
        }

  defstruct get: &__MODULE__.noop_1/1,
            abort: &__MODULE__.noop_2/2,
            retry: &__MODULE__.noop_2/2,
            delete: &__MODULE__.noop_1/1

  @doc false
  @spec noop_1(term()) :: {:error, :not_wired}
  def noop_1(_arg), do: {:error, :not_wired}

  @doc false
  @spec noop_2(term(), term()) :: {:error, :not_wired}
  def noop_2(_arg1, _arg2), do: {:error, :not_wired}
end
