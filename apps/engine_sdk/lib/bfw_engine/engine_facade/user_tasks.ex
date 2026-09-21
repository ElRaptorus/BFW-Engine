defmodule BfwEngine.EngineFacade.UserTasks do
  @moduledoc """
  Runtime namespace for User Task control operations.

  `finish/3` and `cancel/3` accept an explicit `identity` parameter
  because the plugin may be acting on behalf of a specific user.
  The plugin's synthetic identity is used as the fallback when the
  Loader wires the closures.
  """

  @type t :: %__MODULE__{
          finish: (String.t(), term(), struct() -> :ok | {:error, term()}),
          cancel: (String.t(), String.t() | nil, struct() -> :ok | {:error, term()})
        }

  defstruct finish: &__MODULE__.noop_3/3,
            cancel: &__MODULE__.noop_3/3

  @doc false
  @spec noop_3(term(), term(), term()) :: {:error, :not_wired}
  def noop_3(_a, _b, _c), do: {:error, :not_wired}
end
