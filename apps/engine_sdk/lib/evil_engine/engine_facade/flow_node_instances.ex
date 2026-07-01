defmodule EvilEngine.EngineFacade.FlowNodeInstances do
  @moduledoc """
  Runtime namespace for Flow Node Instance reads.

  | Closure | Signature |
  |---------|-----------|
  | `get` | `(String.t()) -> {:ok, struct()} \\| {:error, term()}` |
  | `list_for_process_instance` | `(String.t()) -> {:ok, [struct()]} \\| {:error, term()}` |
  """

  @type t :: %__MODULE__{
          get: (String.t() -> {:ok, struct()} | {:error, term()}),
          list_for_process_instance: (String.t() -> {:ok, [struct()]} | {:error, term()})
        }

  defstruct get: &__MODULE__.noop_1/1,
            list_for_process_instance: &__MODULE__.noop_1/1

  @doc false
  @spec noop_1(term()) :: {:error, :not_wired}
  def noop_1(_arg), do: {:error, :not_wired}
end
