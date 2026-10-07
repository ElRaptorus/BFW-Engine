defmodule BfwEngine.EngineFacade.UserTasks do
  @moduledoc """
  Runtime namespace for User Task control operations. Manual Tasks use
  `BfwEngine.EngineFacade.ManualTasks`.

  `finish/4` is `(flow_node_instance_id, values, action_id, identity)`.
  `cancel/3` is `(flow_node_instance_id, reason, identity)`.
  Both accept an explicit `identity` because the plugin may be acting
  on behalf of a specific user. The plugin's synthetic identity is used
  as the fallback when the Loader wires the closures.
  """

  @type t :: %__MODULE__{
          finish: (String.t(), map(), String.t() | nil, struct() -> :ok | {:error, term()}),
          cancel: (String.t(), String.t() | nil, struct() -> :ok | {:error, term()})
        }

  defstruct finish: &__MODULE__.noop_finish/4,
            cancel: &__MODULE__.noop_3/3

  # Default capture for this module's struct fields.
  @doc false
  @spec noop_finish(term(), term(), term(), term()) :: {:error, :not_wired}
  def noop_finish(_flow_node_instance_id, _values, _action_id, _identity),
    do: {:error, :not_wired}

  # Default capture for this module's struct fields.
  @doc false
  @spec noop_3(term(), term(), term()) :: {:error, :not_wired}
  def noop_3(_flow_node_instance_id, _reason, _identity), do: {:error, :not_wired}
end
