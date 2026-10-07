defmodule BfwEngine.EngineFacade.ManualTasks do
  @moduledoc """
  Runtime namespace for confirming Manual Tasks (`bfw:requireConfirmation`).

  `confirm/2` takes no payload: the token the Manual Task entered with
  continues unchanged. `cancel/3` aborts the whole process instance tree.
  Both accept an explicit `identity` parameter because the plugin may be
  acting on behalf of a specific user.
  """

  @type t :: %__MODULE__{
          confirm: (String.t(), struct() -> :ok | {:error, term()}),
          cancel: (String.t(), String.t() | nil, struct() -> :ok | {:error, term()})
        }

  defstruct confirm: &__MODULE__.noop_2/2,
            cancel: &__MODULE__.noop_3/3

  # Default capture for this module's struct fields.
  @doc false
  @spec noop_2(term(), term()) :: {:error, :not_wired}
  def noop_2(_flow_node_instance_id, _identity), do: {:error, :not_wired}

  # Default capture for this module's struct fields.
  @doc false
  @spec noop_3(term(), term(), term()) :: {:error, :not_wired}
  def noop_3(_flow_node_instance_id, _reason, _identity), do: {:error, :not_wired}
end
