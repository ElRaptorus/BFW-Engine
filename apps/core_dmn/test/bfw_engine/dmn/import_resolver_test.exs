defmodule BfwEngine.DMN.ImportResolverTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias BfwEngine.DMN.ImportResolver
  alias BfwEngine.DMN.Model.Decision
  alias BfwEngine.DMN.Model.Definitions
  alias BfwEngine.DMN.Model.Import
  alias BfwEngine.DMN.Model.InputData
  alias BfwEngine.DMN.ModelCache
  alias BfwEngine.DMN.Parser

  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures", "dmns"])
  @shared_namespace "https://example.com/dmn/shared"
  @helpers_namespace "https://example.com/dmn/helpers"
  @importing_namespace "https://example.com/dmn/importing"

  setup do
    ModelCache.reset_state()
    :ok
  end

  defp read_fixture(name), do: File.read!(Path.join(@fixtures_dir, name))

  defp parse_fixture(name) do
    {:ok, definitions} = Parser.parse(read_fixture(name))
    definitions
  end

  defp sample_definitions(overrides \\ []) do
    defaults = [
      id: "definitions_sample",
      namespace: @shared_namespace,
      decisions: [%Decision{id: "Decision_shared", name: "Shared"}],
      imports: []
    ]

    struct(Definitions, Keyword.merge(defaults, overrides))
  end

  describe "resolve_imports/2" do
    test "returns empty map when there are no imports" do
      definitions = sample_definitions()

      assert {:ok, %{}} = ImportResolver.resolve_imports(definitions, fn _ -> {:error, :missing} end)
    end

    test "resolves each import namespace via the resolver" do
      shared_definitions = sample_definitions()
      helpers_definitions = sample_definitions(namespace: @helpers_namespace, id: "definitions_helpers")

      importing_definitions =
        sample_definitions(
          namespace: @importing_namespace,
          imports: [
            %Import{namespace: @shared_namespace, import_type: "dmn"},
            %Import{namespace: @helpers_namespace, import_type: "dmn"}
          ]
        )

      shared_namespace = @shared_namespace
      helpers_namespace = @helpers_namespace

      resolver = fn
        ^shared_namespace -> {:ok, shared_definitions}
        ^helpers_namespace -> {:ok, helpers_definitions}
        _ -> {:error, :not_found}
      end

      assert {:ok, resolved} = ImportResolver.resolve_imports(importing_definitions, resolver)
      assert map_size(resolved) == 2
      assert resolved[@shared_namespace].id == "definitions_sample"
      assert resolved[@helpers_namespace].id == "definitions_helpers"
    end

    test "returns import_not_found when a namespace is missing" do
      importing_definitions =
        sample_definitions(
          imports: [%Import{namespace: @shared_namespace, import_type: "dmn"}]
        )

      assert {:error, :import_not_found, %{namespace: @shared_namespace}} =
               ImportResolver.resolve_imports(importing_definitions, fn _ ->
                 {:error, :not_found}
               end)
    end
  end

  describe "detect_circular_imports/2" do
    test "returns ok for a linear import chain" do
      model_a =
        sample_definitions(
          namespace: "https://example.com/a",
          imports: [%Import{namespace: "https://example.com/b", import_type: "dmn"}]
        )

      model_b = sample_definitions(namespace: "https://example.com/b", imports: [])

      resolver = fn
        "https://example.com/a" -> {:ok, model_a}
        "https://example.com/b" -> {:ok, model_b}
        _ -> {:error, :not_found}
      end

      assert :ok = ImportResolver.detect_circular_imports("https://example.com/a", resolver)
    end

    test "detects a direct circular import" do
      model_a =
        sample_definitions(
          namespace: "https://example.com/a",
          imports: [%Import{namespace: "https://example.com/b", import_type: "dmn"}]
        )

      model_b =
        sample_definitions(
          namespace: "https://example.com/b",
          imports: [%Import{namespace: "https://example.com/a", import_type: "dmn"}]
        )

      resolver = fn
        "https://example.com/a" -> {:ok, model_a}
        "https://example.com/b" -> {:ok, model_b}
        _ -> {:error, :not_found}
      end

      assert {:error, :circular_import, %{chain: chain}} =
               ImportResolver.detect_circular_imports("https://example.com/a", resolver)

      assert "https://example.com/a" in chain
      assert "https://example.com/b" in chain
    end
  end

  describe "validate_imports/2" do
    test "returns resolved imports when all namespaces are reachable and acyclic" do
      shared_definitions = sample_definitions()
      helpers_definitions = sample_definitions(namespace: @helpers_namespace)

      importing_definitions =
        sample_definitions(
          namespace: @importing_namespace,
          imports: [
            %Import{namespace: @shared_namespace, import_type: "dmn"},
            %Import{namespace: @helpers_namespace, import_type: "dmn"}
          ]
        )

      shared_namespace = @shared_namespace
      helpers_namespace = @helpers_namespace

      resolver = fn
        ^shared_namespace -> {:ok, shared_definitions}
        ^helpers_namespace -> {:ok, helpers_definitions}
        _ -> {:error, :not_found}
      end

      assert {:ok, resolved} = ImportResolver.validate_imports(importing_definitions, resolver)
      assert Map.has_key?(resolved, @shared_namespace)
      assert Map.has_key?(resolved, @helpers_namespace)
    end

    test "returns violations when an import is not deployed" do
      importing_definitions =
        sample_definitions(
          namespace: @importing_namespace,
          imports: [%Import{namespace: @shared_namespace, import_type: "dmn"}]
        )

      assert {:error, [{:import_not_found, message}]} =
               ImportResolver.validate_imports(importing_definitions, fn _ -> {:error, :not_found} end)

      assert message =~ @shared_namespace
    end

    test "returns violations for circular imports on the deploying model" do
      model_b =
        sample_definitions(
          namespace: @helpers_namespace,
          imports: [%Import{namespace: @importing_namespace, import_type: "dmn"}]
        )

      importing_definitions =
        sample_definitions(
          namespace: @importing_namespace,
          imports: [%Import{namespace: @helpers_namespace, import_type: "dmn"}]
        )

      helpers_namespace = @helpers_namespace

      resolver = fn
        ^helpers_namespace -> {:ok, model_b}
        _ -> {:error, :not_found}
      end

      assert {:error, [{:circular_import, message}]} =
               ImportResolver.validate_imports(importing_definitions, resolver)

      assert message =~ "Circular import"
    end
  end

  describe "resolve_imported_element/3" do
    test "resolves a local decision by id" do
      decision = %Decision{id: "Decision_local", name: "Local"}
      local_definitions = sample_definitions(decisions: [decision])

      assert {:ok, {:decision, ^decision}} =
               ImportResolver.resolve_imported_element("Decision_local", local_definitions, %{})
    end

    test "resolves a local input data element by id" do
      input_data = %InputData{id: "InputData_age", name: "age"}
      local_definitions = sample_definitions(input_data: [input_data])

      assert {:ok, {:input_data, ^input_data}} =
               ImportResolver.resolve_imported_element("InputData_age", local_definitions, %{})
    end

    test "resolves an imported decision via namespace-qualified reference" do
      imported_decision = %Decision{id: "Decision_external", name: "External"}
      imported_definitions = sample_definitions(decisions: [imported_decision])
      local_definitions = sample_definitions(namespace: @importing_namespace)

      qualified_reference = "#{@shared_namespace}#Decision_external"

      assert {:ok, {:decision, ^imported_decision}} =
               ImportResolver.resolve_imported_element(
                 qualified_reference,
                 local_definitions,
                 %{@shared_namespace => imported_definitions}
               )
    end

    test "returns import_not_found when the namespace is absent from resolved imports" do
      local_definitions = sample_definitions(namespace: @importing_namespace)
      qualified_reference = "#{@shared_namespace}#Decision_external"

      assert {:error, :import_not_found, %{namespace: @shared_namespace}} =
               ImportResolver.resolve_imported_element(qualified_reference, local_definitions, %{})
    end

    test "returns element_not_found when the id does not exist in the target model" do
      imported_definitions = sample_definitions()
      local_definitions = sample_definitions(namespace: @importing_namespace)
      qualified_reference = "#{@shared_namespace}#Decision_missing"

      assert {:error, :element_not_found, metadata} =
               ImportResolver.resolve_imported_element(
                 qualified_reference,
                 local_definitions,
                 %{@shared_namespace => imported_definitions}
               )

      assert metadata.element_id == "Decision_missing"
    end

    test "returns invalid_qualified_reference for malformed references" do
      local_definitions = sample_definitions()
      malformed_reference = "https://example.com/dmn/namespace-only#"

      assert {:error, :invalid_qualified_reference, %{qualified_reference: ^malformed_reference}} =
               ImportResolver.resolve_imported_element(malformed_reference, local_definitions, %{})
    end

    test "resolves bare #elementId as local reference" do
      decision = %Decision{id: "Decision_local", name: "Local"}
      local_definitions = sample_definitions(decisions: [decision])

      assert {:ok, {:decision, ^decision}} =
               ImportResolver.resolve_imported_element("#Decision_local", local_definitions, %{})
    end

    test "resolves an imported BKM element via qualified reference" do
      alias BfwEngine.DMN.Model.BusinessKnowledgeModel

      imported_bkm = %BusinessKnowledgeModel{id: "BKM_helper", name: "Helper"}
      imported_definitions = sample_definitions(business_knowledge_models: [imported_bkm])
      local_definitions = sample_definitions(namespace: @importing_namespace)

      qualified_reference = "#{@shared_namespace}#BKM_helper"

      assert {:ok, {:business_knowledge_model, ^imported_bkm}} =
               ImportResolver.resolve_imported_element(
                 qualified_reference,
                 local_definitions,
                 %{@shared_namespace => imported_definitions}
               )
    end
  end

  describe "build_model_cache_resolver/0" do
    test "looks up definitions by namespace from ModelCache" do
      shared_definitions = sample_definitions()
      :ok = ModelCache.put_new("version-shared", shared_definitions)

      resolver = ImportResolver.build_model_cache_resolver()

      assert {:ok, ^shared_definitions} = resolver.(@shared_namespace)
      assert {:error, :not_found} = resolver.("https://example.com/unknown")
    end

    test "integrates with validate_imports via ModelCache" do
      shared_definitions = sample_definitions()
      :ok = ModelCache.put_new("version-shared", shared_definitions)

      importing_definitions =
        sample_definitions(
          namespace: @importing_namespace,
          imports: [%Import{namespace: @shared_namespace, import_type: "dmn"}]
        )

      assert {:ok, resolved} =
               ImportResolver.validate_imports(importing_definitions, ImportResolver.build_model_cache_resolver())

      assert resolved[@shared_namespace].namespace == @shared_namespace
    end
  end

  describe "parse fixture import_element.dmn" do
    test "validate_imports resolves fixture imports with a stub resolver" do
      importing_definitions = parse_fixture("import_element.dmn")

      assert length(importing_definitions.imports) == 2

      resolver = fn
        "https://example.com/dmn/shared-types" ->
          {:ok, sample_definitions(namespace: "https://example.com/dmn/shared-types")}

        "https://example.com/dmn/helpers" ->
          {:ok, sample_definitions(namespace: "https://example.com/dmn/helpers")}

        _ ->
          {:error, :not_found}
      end

      assert {:ok, resolved} = ImportResolver.validate_imports(importing_definitions, resolver)
      assert map_size(resolved) == 2
    end
  end
end
