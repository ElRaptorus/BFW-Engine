defmodule Examples.BusinessRules.DecisionRegressionTester.TestInputs do
  @moduledoc """
  Hardcoded fixture inputs for tax bracket regression comparison.
  """

  @doc "Returns every test input map used by the regression worker demo."
  @spec all() :: [map()]
  def all do
    [
      %{"annualIncome" => 10_000, "filingStatus" => "single"},
      %{"annualIncome" => 25_000, "filingStatus" => "single"},
      %{"annualIncome" => 50_000, "filingStatus" => "single"},
      %{"annualIncome" => 100_000, "filingStatus" => "single"},
      %{"annualIncome" => 250_000, "filingStatus" => "single"},
      %{"annualIncome" => 20_000, "filingStatus" => "joint"},
      %{"annualIncome" => 60_000, "filingStatus" => "joint"},
      %{"annualIncome" => 150_000, "filingStatus" => "joint"},
      %{"annualIncome" => 200_000, "filingStatus" => "joint"}
    ]
  end
end
