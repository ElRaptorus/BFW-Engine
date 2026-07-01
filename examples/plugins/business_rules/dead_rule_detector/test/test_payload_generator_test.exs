defmodule Examples.BusinessRules.DeadRuleDetector.TestPayloadGeneratorTest do
  use ExUnit.Case

  alias Examples.BusinessRules.DeadRuleDetector.TestPayloadGenerator

  test "generate_all returns nine varied payloads" do
    payloads = TestPayloadGenerator.generate_all()
    assert length(payloads) == 9
  end

  test "each payload includes all required input keys" do
    required_keys = TestPayloadGenerator.required_keys()

    for payload <- TestPayloadGenerator.generate_all() do
      assert Map.keys(payload) |> Enum.sort() == Enum.sort(required_keys)
    end
  end

  test "payloads cover multiple departments, employee types, and performance ratings" do
    payloads = TestPayloadGenerator.generate_all()

    departments =
      payloads
      |> Enum.map(&Map.get(&1, "department"))
      |> MapSet.new()

    employee_types =
      payloads
      |> Enum.map(&Map.get(&1, "employeeType"))
      |> MapSet.new()

    performance_ratings =
      payloads
      |> Enum.map(&Map.get(&1, "performanceRating"))
      |> MapSet.new()

    assert MapSet.size(departments) >= 4
    assert MapSet.member?(employee_types, "full_time")
    assert MapSet.member?(employee_types, "part_time")
    assert MapSet.member?(employee_types, "contractor")
    assert MapSet.member?(performance_ratings, "outstanding")
    assert MapSet.member?(performance_ratings, "exceeds")
    assert MapSet.member?(performance_ratings, "meets")
    refute MapSet.member?(departments, "discontinued_dept")
  end
end
