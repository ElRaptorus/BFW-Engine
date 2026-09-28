defmodule BfwEngine.EngineFacade.ServiceTasks do
  @moduledoc """
  Runtime namespace for async Service Task control.

  Provides closures for completing or failing a parked async
  Service Task, and for listing the Service Tasks still waiting
  after a restart. The `Loader` wires each closure to the
  corresponding `BfwEngine.Api` function.

  `list_waiting.([implementation])` returns
  `{:ok, [%{flow_node_instance_id, process_instance_id, flow_node_id, implementation, input_token}]}`
  or `{:error, term()}`. The unwired default returns `{:error, :not_wired}`.
  """

  @type t :: %__MODULE__{
          finish_async: (String.t(), term() -> :ok | {:error, term()}),
          fail_async: (String.t(), String.t(), String.t() -> :ok | {:error, term()}),
          list_waiting: ([String.t()] -> {:ok, [map()]} | {:error, term()})
        }

  defstruct finish_async: &__MODULE__.noop_2/2,
            fail_async: &__MODULE__.noop_3/3,
            list_waiting: &__MODULE__.noop_1/1

  @doc false
  @spec noop_1(term()) :: {:error, :not_wired}
  def noop_1(_implementations), do: {:error, :not_wired}

  @doc false
  @spec noop_2(term(), term()) :: {:error, :not_wired}
  def noop_2(_a, _b), do: {:error, :not_wired}

  @doc false
  @spec noop_3(term(), term(), term()) :: {:error, :not_wired}
  def noop_3(_a, _b, _c), do: {:error, :not_wired}
end
