defmodule BfwEngine.DMN.ModelCacheTelemetryTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias BfwEngine.DMN.Model.Definitions
  alias BfwEngine.DMN.ModelCache

  setup do
    ModelCache.reset_state()

    test_pid = self()
    handler_id = "dmn-cache-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:bfw_engine, :dmn, :cache, :hit],
        [:bfw_engine, :dmn, :cache, :miss]
      ],
      fn event_name, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event_name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  defp sample_definitions(tag) do
    %Definitions{
      id: "definitions_#{tag}",
      namespace: "https://example.com/dmn/#{tag}",
      raw_xml: "<definitions>#{tag}</definitions>"
    }
  end

  describe "fetch/1 cache telemetry" do
    test "emits :hit event when entry is already cached" do
      decision_version_id = "cached-version-hit"
      definitions = sample_definitions("hit")

      assert :ok = ModelCache.put_new(decision_version_id, definitions)
      assert {:ok, ^definitions} = ModelCache.fetch(decision_version_id)

      assert_received {:telemetry_event, [:bfw_engine, :dmn, :cache, :hit], %{count: 1},
                       %{decision_version_id: ^decision_version_id}}
    end

    test "emits :miss event on empty cache before load attempt" do
      decision_version_id = "uncached-version-miss"

      assert {:error, :not_found} = ModelCache.fetch(decision_version_id)

      assert_received {:telemetry_event, [:bfw_engine, :dmn, :cache, :miss], %{count: 1},
                       %{decision_version_id: ^decision_version_id}}
    end
  end
end
