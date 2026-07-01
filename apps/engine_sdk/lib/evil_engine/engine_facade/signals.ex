defmodule EvilEngine.EngineFacade.Signals do
  @moduledoc """
  Runtime namespace for signal operations on the `EngineFacade`.

  Provides a typed closure for publishing signals. The `Loader` wires
  the closure to `SignalPublisher.publish_signal/1` with the plugin's
  identity pre-injected into the origin.

  Signals carry no payload and no correlation — `publish/1` takes only
  the signal name.
  """

  @type publish_result :: {:ok, map()} | {:error, term()}

  @type t :: %__MODULE__{
          publish: (String.t() -> publish_result())
        }

  defstruct publish: &__MODULE__.noop_publish/1

  @doc false
  @spec noop_publish(term()) :: {:error, :not_wired}
  def noop_publish(_signal_name), do: {:error, :not_wired}
end
