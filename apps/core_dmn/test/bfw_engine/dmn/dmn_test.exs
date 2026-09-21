defmodule BfwEngine.DMNTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias BfwEngine.DMN
  alias BfwEngine.DMN.Model.Definitions
  alias BfwEngine.DMN.Parser

  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures", "dmns"])
  defp read_fixture(name), do: File.read!(Path.join(@fixtures_dir, name))

  describe "parse/1" do
    test "delegates to Parser.parse/1" do
      assert {:ok, %Definitions{}} = DMN.parse(read_fixture("simple_unique.dmn"))
    end
  end

  describe "validate/1" do
    test "delegates to Validator.validate/1" do
      {:ok, definitions} = Parser.parse(read_fixture("simple_unique.dmn"))
      assert {:ok, ^definitions} = DMN.validate(definitions)
    end
  end

  describe "parse_and_validate/2" do
    test "returns precompiled definitions on success" do
      assert {:ok, %Definitions{} = definitions} = DMN.parse_and_validate(read_fixture("simple_unique.dmn"))
      assert definitions.decisions != []
    end

    test "short-circuits on parse failure" do
      assert {:error, :dmn_parse_error, %{reason: _reason}} = DMN.parse_and_validate("<definitions><unclosed")
    end

    test "short-circuits on validation failure" do
      assert {:error, :validation_failed, %{violations: violations}} =
               DMN.parse_and_validate(read_fixture("invalid_no_expression.dmn"))

      assert Enum.any?(violations, fn {code, _message} -> code == :invalid_decision end)
    end
  end
end
