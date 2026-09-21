defmodule BfwEngine.DMN.ModelCacheTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias BfwEngine.DMN.Model.Definitions
  alias BfwEngine.DMN.ModelCache

  setup do
    ModelCache.reset_state()
    :ok
  end

  defp sample_definitions(tag \\ "test") do
    %Definitions{
      id: "definitions_#{tag}",
      namespace: "https://example.com/dmn/#{tag}",
      raw_xml: "<definitions>#{tag}</definitions>"
    }
  end

  describe "put_new/2 and fetch/1" do
    test "caches and retrieves a definitions struct" do
      definitions = sample_definitions()
      assert :ok = ModelCache.put_new("v1", definitions)
      assert {:ok, ^definitions} = ModelCache.fetch("v1")
    end

    test "put_new is idempotent — second put does not overwrite" do
      definitions_a = sample_definitions("a")
      definitions_b = sample_definitions("b")

      assert :ok = ModelCache.put_new("v1", definitions_a)
      assert :ok = ModelCache.put_new("v1", definitions_b)

      assert {:ok, ^definitions_a} = ModelCache.fetch("v1")
    end
  end

  describe "delete/1" do
    test "removes a cached entry" do
      definitions = sample_definitions()
      ModelCache.put_new("v1", definitions)

      assert :ok = ModelCache.delete("v1")
      assert {:error, :not_found} = ModelCache.fetch("v1")
    end

    test "succeeds silently for non-existent key" do
      assert :ok = ModelCache.delete("nonexistent")
    end

    test "deleted entry no longer appears in list_cached_ids" do
      ModelCache.put_new("v1", sample_definitions("one"))
      ModelCache.put_new("v2", sample_definitions("two"))

      ModelCache.delete("v1")

      cached_ids = ModelCache.list_cached_ids()
      refute "v1" in cached_ids
      assert "v2" in cached_ids
    end
  end

  describe "list_cached_ids/0" do
    test "returns empty list when cache is empty" do
      assert [] = ModelCache.list_cached_ids()
    end

    test "returns all cached version IDs" do
      ModelCache.put_new("v1", sample_definitions("one"))
      ModelCache.put_new("v2", sample_definitions("two"))
      ModelCache.put_new("v3", sample_definitions("three"))

      ids = ModelCache.list_cached_ids()
      assert length(ids) == 3
      assert "v1" in ids
      assert "v2" in ids
      assert "v3" in ids
    end
  end

  describe "reset_state/0" do
    test "clears all cached entries" do
      ModelCache.put_new("v1", sample_definitions("one"))
      ModelCache.put_new("v2", sample_definitions("two"))

      assert :ok = ModelCache.reset_state()
      assert [] = ModelCache.list_cached_ids()
      assert {:error, :not_found} = ModelCache.fetch("v1")
    end
  end

  describe "get/1" do
    test "returns definitions for cached key" do
      definitions = sample_definitions()
      ModelCache.put_new("v1", definitions)

      assert ^definitions = ModelCache.get("v1")
    end

    test "returns nil for missing key" do
      assert nil == ModelCache.get("nonexistent")
    end
  end

  describe "fetch/1 — cache miss with loader" do
    test "fetch returns :not_found when no loader is configured" do
      assert {:error, :not_found} = ModelCache.fetch("nonexistent-version-id")
    end

    test "concurrent waiters all receive the same result" do
      definitions = sample_definitions("concurrent")
      ModelCache.put_new("concurrent-v1", definitions)

      tasks =
        for _i <- 1..10 do
          Task.async(fn -> ModelCache.fetch("concurrent-v1") end)
        end

      results = Task.await_many(tasks, 5_000)

      for result <- results do
        assert {:ok, ^definitions} = result
      end
    end

    test "concurrent fetch on cold cache does not crash" do
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            ModelCache.fetch("cold-cache-key-#{i}")
          end)
        end

      results = Task.await_many(tasks, 5_000)

      for result <- results do
        assert {:error, _reason} = result
      end

      assert Process.alive?(Process.whereis(ModelCache))
    end
  end

  describe "lookup_by_namespace/1" do
    test "returns definitions for a cached namespace" do
      definitions = sample_definitions("indexed")
      ModelCache.put_new("v1", definitions)

      assert {:ok, ^definitions} = ModelCache.lookup_by_namespace("https://example.com/dmn/indexed")
    end

    test "returns :not_found for unknown namespace" do
      assert {:error, :not_found} = ModelCache.lookup_by_namespace("https://example.com/dmn/unknown")
    end

    test "latest put_new wins when multiple versions share a namespace" do
      definitions_a = %Definitions{
        id: "definitions_a",
        namespace: "https://example.com/dmn/shared",
        raw_xml: "<definitions>a</definitions>"
      }

      definitions_b = %Definitions{
        id: "definitions_b",
        namespace: "https://example.com/dmn/shared",
        raw_xml: "<definitions>b</definitions>"
      }

      ModelCache.put_new("v1", definitions_a)
      ModelCache.put_new("v2", definitions_b)

      assert {:ok, result} = ModelCache.lookup_by_namespace("https://example.com/dmn/shared")
      assert result.id == "definitions_b"
    end

    test "namespace index is cleaned up on delete" do
      definitions = sample_definitions("cleanup")
      ModelCache.put_new("v1", definitions)

      assert {:ok, _} = ModelCache.lookup_by_namespace("https://example.com/dmn/cleanup")

      ModelCache.delete("v1")

      assert {:error, :not_found} = ModelCache.lookup_by_namespace("https://example.com/dmn/cleanup")
    end

    test "delete backfills namespace index from remaining versions" do
      definitions_a = %Definitions{
        id: "definitions_a",
        namespace: "https://example.com/dmn/backfill",
        raw_xml: "<definitions>a</definitions>"
      }

      definitions_b = %Definitions{
        id: "definitions_b",
        namespace: "https://example.com/dmn/backfill",
        raw_xml: "<definitions>b</definitions>"
      }

      ModelCache.put_new("v1", definitions_a)
      ModelCache.put_new("v2", definitions_b)

      ModelCache.delete("v2")

      assert {:ok, result} = ModelCache.lookup_by_namespace("https://example.com/dmn/backfill")
      assert result.id == "definitions_a"
    end

    test "reset_state clears the namespace index" do
      ModelCache.put_new("v1", sample_definitions("reset"))

      assert {:ok, _} = ModelCache.lookup_by_namespace("https://example.com/dmn/reset")

      ModelCache.reset_state()

      assert {:error, :not_found} = ModelCache.lookup_by_namespace("https://example.com/dmn/reset")
    end

    test "nil namespace is not indexed" do
      definitions = %Definitions{id: "no_ns", namespace: nil, raw_xml: "<definitions/>"}
      ModelCache.put_new("v-nil", definitions)

      assert {:ok, ^definitions} = ModelCache.fetch("v-nil")
    end
  end

  describe "handle_info resilience (P2.2)" do
    test "task result for unknown ref is silently ignored" do
      fake_ref = make_ref()
      send(ModelCache, {fake_ref, {:ok, sample_definitions()}})

      Process.sleep(50)
      assert Process.alive?(Process.whereis(ModelCache))
    end

    test "DOWN message for unknown ref is silently ignored" do
      fake_ref = make_ref()
      send(ModelCache, {:DOWN, fake_ref, :process, self(), :normal})

      Process.sleep(50)
      assert Process.alive?(Process.whereis(ModelCache))
    end

    test "task result with known ref but missing inflight entry does not crash" do
      state = :sys.get_state(ModelCache)

      fake_ref = make_ref()
      poisoned_state = %{state | ref_to_id: Map.put(state.ref_to_id, fake_ref, "orphan_id")}
      :sys.replace_state(ModelCache, fn _ -> poisoned_state end)

      send(ModelCache, {fake_ref, {:ok, sample_definitions("orphan")}})

      Process.sleep(50)
      assert Process.alive?(Process.whereis(ModelCache))
      refute "orphan_id" in ModelCache.list_cached_ids()
    end

    test "DOWN with known ref but missing inflight entry does not crash" do
      state = :sys.get_state(ModelCache)

      fake_ref = make_ref()
      poisoned_state = %{state | ref_to_id: Map.put(state.ref_to_id, fake_ref, "orphan_down")}
      :sys.replace_state(ModelCache, fn _ -> poisoned_state end)

      send(ModelCache, {:DOWN, fake_ref, :process, self(), :boom})

      Process.sleep(50)
      assert Process.alive?(Process.whereis(ModelCache))
    end
  end
end
