defmodule EvilEngine.Persistence.Checks.ObserveAll do
  @moduledoc """
  Ash policy check: passes when the actor carries `observe_all: true`.

  This is a **read/observe** bypass only. It must never be attached to
  create, update, or destroy policies — unlike `ZeekyBoogieDoog`, it
  never grants write.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor has observe_all unbounded read"

  @impl true
  def match?(%{observe_all: true}, _, _), do: true
  def match?(_, _, _), do: false
end
