defmodule BfwEngine.Persistence.Checks.ZeekyBoogieDoog do
  @moduledoc """
  Ash policy check: passes when the actor carries the `zeeky_boogie_doog`
  admin-override flag.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor has zeeky_boogie_doog admin override"

  @impl true
  def match?(%{zeeky_boogie_doog: true}, _, _), do: true
  def match?(_, _, _), do: false
end
