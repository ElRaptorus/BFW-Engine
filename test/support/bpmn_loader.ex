defmodule EvilEngine.Test.BpmnLoader do
  @moduledoc """
  Loads `.bpmn` fixture files, parses them, and stores the AST
  in the ModelCache for execution integration tests.
  """

  @fixtures_dir Path.expand("../fixtures/bpmns", __DIR__)

  @doc """
  Parse a BPMN fixture file and store the result in ModelCache.

  Returns `{:ok, definitions}` where `definitions` is the parsed `%Definitions{}`.
  """
  def deploy_fixture(fixture_name, process_version_id) do
    path = Path.join(@fixtures_dir, fixture_name)
    xml = File.read!(path)
    {:ok, definitions} = EvilEngine.BPMN.parse_and_validate(xml)
    EvilEngine.BPMN.ModelCache.put_new(process_version_id, definitions)
    {:ok, definitions}
  end
end
