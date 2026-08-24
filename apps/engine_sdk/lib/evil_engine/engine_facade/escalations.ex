defmodule EvilEngine.EngineFacade.Escalations do
  @moduledoc """
  Runtime namespace for escalation inject operations on the `EngineFacade`.

  Provides a typed closure for publishing an escalation code to waiting
  catchers. The `Loader` wires the closure to
  `EvilEngine.Api.trigger_escalation/3` with `skip_claims: true`.

  Escalations carry no payload — `publish/1` takes only the escalation
  code.
  """

  @type publish_result :: {:ok, map()} | {:error, term()}

  @type t :: %__MODULE__{
          publish: (String.t() -> publish_result())
        }

  defstruct publish: &__MODULE__.noop_publish/1

  @doc false
  @spec noop_publish(term()) :: {:error, :not_wired}
  def noop_publish(_escalation_code), do: {:error, :not_wired}
end
