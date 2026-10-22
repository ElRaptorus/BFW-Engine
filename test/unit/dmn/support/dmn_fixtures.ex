defmodule BfwEngine.Test.DmnFixtures do
  @moduledoc false

  @unit_fixtures_dir Path.expand("../fixtures/dmns", __DIR__)
  @shared_fixtures_dir Path.expand("../../../fixtures/dmns", __DIR__)

  @doc "Reads a DMN fixture: the DMN unit copy when one exists, else `test/fixtures/dmns`."
  def read!(name) do
    unit_path = Path.join(@unit_fixtures_dir, name)

    if File.exists?(unit_path) do
      File.read!(unit_path)
    else
      File.read!(Path.join(@shared_fixtures_dir, name))
    end
  end
end
