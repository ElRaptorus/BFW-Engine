defmodule BfwEngine.EngineFacade.Messages do
  @moduledoc """
  Runtime namespace for message operations on the `EngineFacade`.

  Provides a typed closure for publishing messages. The `Loader` wires
  the closure to `MessagePublisher.publish_message/1` with the plugin's
  identity pre-injected into the origin.
  """

  @type publish_result :: {:ok, map()} | {:error, term()}

  @type t :: %__MODULE__{
          publish: (String.t(), String.t() | nil, map() -> publish_result())
        }

  defstruct publish: &__MODULE__.noop_publish/3

  @doc false
  @spec noop_publish(term(), term(), term()) :: {:error, :not_wired}
  def noop_publish(_message_name, _correlation_value, _payload), do: {:error, :not_wired}
end
