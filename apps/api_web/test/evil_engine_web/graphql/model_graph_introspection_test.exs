defmodule EvilEngineWeb.Graphql.ModelGraphIntrospectionTest do
  @moduledoc """
  Schema-introspection tests for the BPMN Model graph (Phase 6.1, WP-7).

  Pure unit tests — no database, no HTTP. They walk the compiled Absinthe
  schema (`EvilEngineWeb.Graphql.Schema`) and the `core_bpmn` module list
  directly, so a new `FlowNodeData.*` struct or a reintroduced compiled
  artifact fails the suite without needing an end-to-end query.
  """
  use ExUnit.Case, async: true

  alias EvilEngineWeb.Graphql.Schema

  @flow_node_data_prefix "Elixir.EvilEngine.BPMN.Model.FlowNodeData."
  @event_definition_prefix "Elixir.EvilEngine.BPMN.Model.EventDefinition."

  # WP-7 test (i): every `FlowNodeData.*` struct has a matching GraphQL
  # concrete type. Enumerated from the compiled `core_bpmn` module list
  # (not hand-copied), so a newly added struct fails this test instead of
  # silently missing a type.
  describe "test (i) — FlowNodeData struct <-> GraphQL type alignment" do
    test "every FlowNodeData.* module has a corresponding *_node Absinthe type implementing the flow_node interface" do
      flow_node_data_modules()
      |> Enum.each(fn module ->
        identifier = struct_module_to_node_identifier(module)
        type = Absinthe.Schema.lookup_type(Schema, identifier)

        assert type != nil,
               "#{inspect(module)} has no matching GraphQL type #{inspect(identifier)}. " <>
                 "Add a concrete `*Node` object type in model_types.ex and register it on the " <>
                 ":flow_node interface's resolve_type/1 and the :flow_node_type enum."

        assert :flow_node in (type.interfaces || []),
               "#{inspect(identifier)} exists but does not implement the :flow_node interface."
      end)
    end

    test "the flow_node_type enum has exactly one value per FlowNodeData.* module" do
      enum_type = Absinthe.Schema.lookup_type(Schema, :flow_node_type)
      enum_values = enum_type.values |> Map.keys() |> MapSet.new()

      expected_values =
        flow_node_data_modules()
        |> Enum.map(&struct_module_to_snake_atom/1)
        |> MapSet.new()

      assert enum_values == expected_values,
             "flow_node_type enum drifted from FlowNodeData.* structs.\n" <>
               "Missing from enum: #{inspect(MapSet.difference(expected_values, enum_values) |> MapSet.to_list())}\n" <>
               "Stale in enum: #{inspect(MapSet.difference(enum_values, expected_values) |> MapSet.to_list())}"
    end

    test "there is no *_node type without a backing FlowNodeData.* module (no orphaned GraphQL types)" do
      expected_identifiers =
        flow_node_data_modules()
        |> Enum.map(&struct_module_to_node_identifier/1)
        |> MapSet.new()

      actual_node_identifiers =
        Schema
        |> Absinthe.Schema.types()
        |> Enum.map(& &1.identifier)
        |> Enum.filter(&(&1 != :flow_node and String.ends_with?(Atom.to_string(&1), "_node")))
        |> MapSet.new()

      assert actual_node_identifiers == expected_identifiers
    end

    test "every EventDefinition.* module has a corresponding *_event_definition Absinthe type in the event_definition union" do
      union_type = Absinthe.Schema.lookup_type(Schema, :event_definition)
      union_members = MapSet.new(union_type.types)

      event_definition_modules()
      |> Enum.each(fn module ->
        identifier = struct_module_to_event_definition_identifier(module)

        assert identifier in union_members,
               "#{inspect(module)} has no matching member #{inspect(identifier)} on the " <>
                 ":event_definition union. Add an object type and register it in the union's " <>
                 "types/1 and resolve_type/1."
      end)

      assert MapSet.size(union_members) == length(event_definition_modules())
    end
  end

  # WP-7 test (iv): no compiled/opaque artifact is reachable through
  # introspection. `FieldTable.excluded` documents these exclusions at the
  # source level; this test verifies the exclusion actually holds in the
  # compiled schema, so an accidental re-exposure fails here too.
  describe "test (iv) — no compiled artifact is reachable via introspection" do
    @compiled_artifact_pattern ~r/compiled|precompiled|raw_xml/i

    test "no field name or identifier across the entire schema matches a compiled-artifact pattern" do
      offenders =
        Schema
        |> Absinthe.Schema.types()
        |> Enum.flat_map(fn type ->
          type
          |> Map.get(:fields, %{})
          |> Enum.filter(fn {identifier, _field} ->
            Regex.match?(@compiled_artifact_pattern, Atom.to_string(identifier))
          end)
          |> Enum.map(fn {identifier, _field} -> {type.identifier, identifier} end)
        end)

      assert offenders == [],
             "Compiled/opaque artifact(s) leaked into the GraphQL schema: #{inspect(offenders)}"
    end
  end

  # Completes D-3: `verify!/0` only checks Elixir struct keys against the
  # table. This test checks that every `exposed` key actually exists on the
  # Absinthe type `FieldTable.graphql_identifier/1` names, so a table row
  # that says "exposed" cannot silently omit the GraphQL field (the
  # SendTask.out_mappings hole this test was added to close).
  describe "FieldTable exposed keys are present on the Absinthe type" do
    alias EvilEngineWeb.Graphql.ModelSchema.FieldTable

    test "every FieldTable exposed atom is a field on the mapped GraphQL type" do
      missing =
        Enum.flat_map(FieldTable.registry(), fn {module, opts} ->
          graphql_identifier = FieldTable.graphql_identifier(module)
          type = Absinthe.Schema.lookup_type(Schema, graphql_identifier)

          assert type != nil,
                 "#{inspect(module)} maps to #{inspect(graphql_identifier)} but that Absinthe type does not exist"

          field_identifiers = absinthe_field_identifiers(type)

          opts
          |> Keyword.fetch!(:exposed)
          |> Enum.reject(&MapSet.member?(field_identifiers, &1))
          |> Enum.map(&{module, graphql_identifier, &1})
        end)

      assert missing == [],
             "FieldTable lists these as exposed but they are missing from the GraphQL type: #{inspect(missing)}"
    end

    test "every EvilEngine.BPMN.Model.* struct module is registered in FieldTable" do
      registered =
        FieldTable.registry()
        |> Enum.map(&elem(&1, 0))
        |> MapSet.new()

      model_structs =
        :core_bpmn
        |> Application.spec(:modules)
        |> Enum.filter(fn module ->
          String.starts_with?(Atom.to_string(module), "Elixir.EvilEngine.BPMN.Model.")
        end)
        |> tap(fn modules -> Enum.each(modules, &Code.ensure_loaded!/1) end)
        |> Enum.filter(&function_exported?(&1, :__struct__, 0))
        |> MapSet.new()

      assert registered == model_structs,
             "FieldTable registry drifted from Model.* structs.\n" <>
               "Unregistered: #{inspect(MapSet.difference(model_structs, registered) |> MapSet.to_list())}\n" <>
               "Stale: #{inspect(MapSet.difference(registered, model_structs) |> MapSet.to_list())}"
    end
  end

  # ---------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------

  defp flow_node_data_modules do
    modules_under_prefix(@flow_node_data_prefix)
  end

  defp event_definition_modules do
    modules_under_prefix(@event_definition_prefix)
  end

  defp modules_under_prefix(prefix) do
    :core_bpmn
    |> Application.spec(:modules)
    |> Enum.map(&Atom.to_string/1)
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(&String.to_existing_atom/1)
    |> Enum.sort()
  end

  defp struct_module_to_snake_atom(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end

  defp struct_module_to_node_identifier(module) do
    :"#{struct_module_to_snake_atom(module)}_node"
  end

  defp struct_module_to_event_definition_identifier(module) do
    :"#{struct_module_to_snake_atom(module)}_event_definition"
  end

  defp absinthe_field_identifiers(type) do
    fields =
      case Map.get(type, :fields) do
        fields when is_map(fields) -> fields
        fields when is_function(fields, 0) -> fields.()
        _other -> %{}
      end

    fields
    |> Map.keys()
    |> MapSet.new()
  end
end
