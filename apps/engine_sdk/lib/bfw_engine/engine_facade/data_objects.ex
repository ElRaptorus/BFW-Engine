defmodule BfwEngine.EngineFacade.DataObjects do
  @moduledoc """
  Runtime namespace for Data Object reads.

  Provides typed closures for fetching a single Data Object value,
  listing current values for a process instance, and retrieving
  the full audit history.
  """

  @type t :: %__MODULE__{
          get: (String.t() -> {:ok, struct()} | {:error, term()}),
          list_for_instance: (String.t() -> {:ok, list()} | {:error, term()}),
          history_for_instance: (String.t() -> {:ok, list()} | {:error, term()})
        }

  defstruct get: &__MODULE__.noop_1/1,
            list_for_instance: &__MODULE__.noop_1/1,
            history_for_instance: &__MODULE__.noop_1/1

  @doc false
  @spec noop_1(term()) :: {:error, :not_wired}
  def noop_1(_arg), do: {:error, :not_wired}
end
