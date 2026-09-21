defmodule BfwEngine.Conformance.DmnConformanceTest do
  @moduledoc """
  YAML-driven DMN conformance specs (C40–C61).

  All specs with `type: dmn` are executed by `BfwEngine.Test.DmnConformanceRunner`.
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Test.DmnConformanceRunner, as: Runner

  @moduletag :conformance

  for yaml_file <- Runner.list_specs() do
    spec = Runner.load_spec(yaml_file)
    basename = Path.basename(yaml_file, ".yaml")

    @spec_data spec

    test "#{basename}: #{spec["name"]}" do
      Runner.run_auto(@spec_data)
    end
  end
end
