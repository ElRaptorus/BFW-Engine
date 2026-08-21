defmodule EvilEngine.SDK.BPMNTest do
  @moduledoc """
  WP-4 re-export surface: `EvilEngine.SDK.BPMN` must reach the engine's
  parser and `ModelCache` without going through HTTP.
  """
  use ExUnit.Case, async: false

  alias EvilEngine.BPMN.Model
  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.SDK.BPMN

  @repo_root Path.expand("../../../../../", __DIR__)
  @linear_fixture Path.join(@repo_root, "test/fixtures/bpmns/linear_start_end.bpmn")

  setup do
    case Process.whereis(ModelCache) do
      nil -> start_supervised!(ModelCache)
      _pid -> :ok
    end

    :ok
  end

  test "parse/1 returns the engine Definitions AST for valid BPMN XML" do
    xml = File.read!(@linear_fixture)
    assert {:ok, %Model.Definitions{} = definitions} = BPMN.parse(xml)
    assert definitions.definitions_id == "Definitions_1"
    assert Enum.any?(definitions.processes, &(&1.id == "LinearStartEnd"))
  end

  test "parse/1 rejects non-binary input" do
    assert {:error, :invalid_input} = BPMN.parse(nil)
  end

  test "cache lookups on an unknown version return not_found without raising" do
    unknown_id = "00000000-0000-0000-0000-000000000000"

    assert {:error, :not_found} = BPMN.fetch_definitions(unknown_id)
    assert BPMN.get_definitions(unknown_id) == nil
    assert {:error, :not_found} = BPMN.fetch_subprocess_model(unknown_id, "SubProcess_1")
    assert BPMN.find_message_start_events("no-such-message") == []
    assert BPMN.find_signal_start_events("no-such-signal") == []
  end
end
