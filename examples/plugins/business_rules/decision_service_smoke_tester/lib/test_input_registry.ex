defmodule Examples.BusinessRules.DecisionServiceSmokeTester.TestInputRegistry do
  @moduledoc """
  Maps deployed decision definition and service IDs to smoke-test input fixtures.
  """

  @doc """
  Returns the test input map for the given definition and service pair.

  Falls back to an empty map when no fixture is registered.
  """
  @spec get(String.t(), String.t()) :: map()
  def get(definition_id, service_id) do
    Map.get(fixtures(), {definition_id, service_id}, %{})
  end

  defp fixtures do
    %{
      {"insurance-pricing", "PricingService"} => %{
        "age" => 35,
        "smoker" => false,
        "coverage" => "standard",
        "preExistingConditions" => 1
      }
    }
  end
end
