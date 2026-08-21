defmodule EvilEngine.BPMN.ExtensionManifestTest do
  @moduledoc """
  Tests for `EvilEngine.BPMN.ExtensionManifest` (WP-5, WP-7).

  Two guarantees:

  1. **Corpus round-trip (WP-5.4):** every `evil:*` element name that
     actually appears in the 382-fixture BPMN corpus is a known manifest
     entry (or an `extensible` container). A parser change that introduces
     a new `evil:*` element without a manifest entry fails this test.
  2. **Generator idempotence (WP-5.3, CI diff-guard companion):** the mix
     task's JSON encoding of `ExtensionManifest.to_map/0` is stable and
     round-trips through `Jason.decode!/1` without loss.
  """

  use ExUnit.Case, async: true

  alias EvilEngine.BPMN.ExtensionManifest

  @repo_root Path.expand("../../../../../", __DIR__)
  @root_fixtures Path.join(@repo_root, "test/fixtures/bpmns")
  @core_fixtures Path.join(@repo_root, "apps/core_bpmn/test/fixtures/bpmns")

  describe "build/0" do
    test "every entry has a well-formed shape" do
      for entry <- ExtensionManifest.build() do
        assert is_binary(entry.element) and entry.element != ""

        assert entry.value_kind in [
                 :feel,
                 :json_schema,
                 :static_string,
                 :integer,
                 :boolean,
                 :mapping
               ]

        assert entry.carrier in [:body, :attributes]
        assert is_list(entry.attributes)
        assert is_list(entry.applicable_to) and entry.applicable_to != []
        assert is_binary(entry.model_field) and entry.model_field != ""
      end
    end

    test "element names are unique" do
      elements = Enum.map(ExtensionManifest.build(), & &1.element)
      assert Enum.uniq(elements) == elements
    end

    test "carrier: :attributes entries declare at least one attribute" do
      for entry <- ExtensionManifest.build(), entry.carrier == :attributes do
        assert entry.attributes != [],
               "#{entry.element} declares carrier: :attributes but no attributes"
      end
    end
  end

  describe "corpus round-trip (WP-5.4)" do
    test "every evil:* element name found in the fixture corpus is a known manifest entry or extensible container" do
      manifest_elements = ExtensionManifest.build() |> Enum.map(& &1.element) |> MapSet.new()
      extensible = ExtensionManifest.extensible() |> MapSet.new()
      known = MapSet.union(manifest_elements, extensible)

      corpus_elements = corpus_evil_elements()

      assert corpus_elements != MapSet.new(),
             "fixture corpus scan found zero evil:* elements — check fixture paths"

      unknown = MapSet.difference(corpus_elements, known)

      assert MapSet.size(unknown) == 0,
             "evil:* elements in the fixture corpus with no manifest entry: #{Enum.join(unknown, ", ")}"
    end
  end

  describe "to_map/0 JSON round-trip" do
    test "encodes and decodes without loss of element names" do
      json = ExtensionManifest.to_map() |> Jason.encode!()
      decoded = Jason.decode!(json)

      decoded_elements = decoded["elements"] |> Enum.map(& &1["element"]) |> MapSet.new()
      original_elements = ExtensionManifest.build() |> Enum.map(& &1.element) |> MapSet.new()

      assert decoded_elements == original_elements
      assert decoded["extensible"] == ExtensionManifest.extensible()
    end

    test "committed JSON files match ExtensionManifest.to_json/0" do
      expected = ExtensionManifest.to_json()

      for relative_path <- [
            "extension-manifest.json",
            "packages/js/sdk/src/generated/extension-manifest.json"
          ] do
        actual = File.read!(Path.join(@repo_root, relative_path))

        assert actual == expected,
               "#{relative_path} is out of date (#{Path.join(@repo_root, relative_path)}). " <>
                 "Run `mix evil.gen.extension_manifest` and commit the result."
      end
    end
  end

  defp corpus_evil_elements do
    [@root_fixtures, @core_fixtures]
    |> Enum.flat_map(&walk_bpmn_files/1)
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> then(&Regex.scan(~r/<\/?evil:([A-Za-z][A-Za-z0-9]*)/, &1))
      |> Enum.map(fn [_, name] -> name end)
    end)
    |> MapSet.new()
  end

  defp walk_bpmn_files(directory) do
    if File.dir?(directory) do
      directory
      |> File.ls!()
      |> Enum.map(&Path.join(directory, &1))
      |> Enum.flat_map(&walk_bpmn_entry/1)
    else
      []
    end
  end

  defp walk_bpmn_entry(full_path) do
    cond do
      File.dir?(full_path) -> walk_bpmn_files(full_path)
      String.ends_with?(full_path, ".bpmn") -> [full_path]
      true -> []
    end
  end
end
