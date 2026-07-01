defmodule Examples.BusinessRules.DeadRuleDetector.TestPayloadGenerator do
  @moduledoc """
  Generates varied employee-benefits test inputs that exercise most DMN rules
  while intentionally omitting branches for dead rules 10, 11, and 12.
  """

  @required_keys ["yearsOfService", "department", "performanceRating", "employeeType"]

  @doc "Returns all fixture payloads for dead-rule coverage analysis."
  @spec generate_all() :: [map()]
  def generate_all do
    [
      %{
        "yearsOfService" => 25,
        "department" => "engineering",
        "performanceRating" => "outstanding",
        "employeeType" => "full_time"
      },
      %{
        "yearsOfService" => 12,
        "department" => "sales",
        "performanceRating" => "outstanding",
        "employeeType" => "full_time"
      },
      %{
        "yearsOfService" => 15,
        "department" => "marketing",
        "performanceRating" => "exceeds",
        "employeeType" => "full_time"
      },
      %{
        "yearsOfService" => 7,
        "department" => "support",
        "performanceRating" => "meets",
        "employeeType" => "full_time"
      },
      %{
        "yearsOfService" => 8,
        "department" => "engineering",
        "performanceRating" => "exceeds",
        "employeeType" => "full_time"
      },
      %{
        "yearsOfService" => 2,
        "department" => "sales",
        "performanceRating" => "meets",
        "employeeType" => "full_time"
      },
      %{
        "yearsOfService" => 0,
        "department" => "executive",
        "performanceRating" => "meets",
        "employeeType" => "full_time"
      },
      %{
        "yearsOfService" => 3,
        "department" => "support",
        "performanceRating" => "meets",
        "employeeType" => "part_time"
      },
      %{
        "yearsOfService" => 1,
        "department" => "engineering",
        "performanceRating" => "meets",
        "employeeType" => "contractor"
      }
    ]
  end

  @doc "Returns the required input keys for each generated payload."
  @spec required_keys() :: [String.t()]
  def required_keys, do: @required_keys
end
