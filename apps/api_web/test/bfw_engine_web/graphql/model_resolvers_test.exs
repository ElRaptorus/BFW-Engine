defmodule BfwEngineWeb.Graphql.ModelResolversTest do
  @moduledoc """
  Unit tests for `BfwEngineWeb.Graphql.ModelResolvers` flattening
  (WP-7 (ii) ModelCache-side half). Parses a nested-subprocess fixture
  and asserts `allFlowNodes` contains every inner-scope id with the
  enclosing shell as `parentSubProcessId`. The HTTP half lives in
  `GraphqlModelGraphWp7Test`.
  """
  use ExUnit.Case, async: true

  alias BfwEngine.BPMN.Model
  alias BfwEngine.BPMN.Parser
  alias BfwEngineWeb.Graphql.ModelResolvers

  @repo_root Path.expand("../../../../../", __DIR__)
  @nested_fixture Path.join(@repo_root, "test/fixtures/bpmns/embedded_subprocess_happy_path.bpmn")
  @fixture_directory Path.join(@repo_root, "test/fixtures/bpmns")

  test "allFlowNodes includes nested subprocess nodes with parentSubProcessId set" do
    xml = File.read!(@nested_fixture)
    assert {:ok, definitions} = Parser.parse(xml)
    assert {:ok, process} = ModelResolvers.select_process(definitions)

    process_model = ModelResolvers.to_graphql_process_model(process, definitions)

    top_level_ids = Enum.map(process_model.flow_nodes, & &1.id)
    assert "Start_1" in top_level_ids
    assert "SubProcess_1" in top_level_ids
    assert "End_1" in top_level_ids
    refute "Sub_Start" in top_level_ids
    refute "Sub_Task" in top_level_ids
    refute "Sub_End" in top_level_ids

    all_by_id = Map.new(process_model.all_flow_nodes, &{&1.id, &1})

    assert all_by_id["Start_1"].parent_sub_process_id == nil
    assert all_by_id["SubProcess_1"].parent_sub_process_id == nil
    assert all_by_id["End_1"].parent_sub_process_id == nil

    assert all_by_id["Sub_Start"].parent_sub_process_id == "SubProcess_1"
    assert all_by_id["Sub_Task"].parent_sub_process_id == "SubProcess_1"
    assert all_by_id["Sub_End"].parent_sub_process_id == "SubProcess_1"
    assert all_by_id["Sub_Task"].type == :task

    assert process_model.definitions_id == "Definitions_1"
  end

  test "select_process rejects zero or multiple executable processes" do
    xml = File.read!(@nested_fixture)
    assert {:ok, definitions} = Parser.parse(xml)

    empty = %{definitions | processes: []}
    assert {:error, :no_executable_process} = ModelResolvers.select_process(empty)

    [process] = definitions.processes
    doubled = %{definitions | processes: [process, %{process | id: "Other"}]}
    assert {:error, :multiple_executable_processes} = ModelResolvers.select_process(doubled)
  end

  test "allFlowNodes matches a direct tree walk across every parseable fixture BPMN" do
    parsed =
      @fixture_directory
      |> walk_bpmn_files()
      |> Enum.flat_map(&parse_executable_process/1)

    assert length(parsed) > 50,
           "fixture corpus walk found too few executable processes (#{length(parsed)}) — check #{@fixture_directory}"

    Enum.each(parsed, fn {path, process, definitions} ->
      process_model = ModelResolvers.to_graphql_process_model(process, definitions)

      expected = walk_flow_node_ids(process.flow_nodes, nil)

      actual =
        Enum.map(process_model.all_flow_nodes, fn node ->
          {node.id, node.type, node.parent_sub_process_id}
        end)

      assert actual == expected,
             "#{Path.relative_to(path, @repo_root)} allFlowNodes drifted from a direct Model.Process tree walk"
    end)
  end

  defp parse_executable_process(path) do
    case Parser.parse(File.read!(path)) do
      {:ok, definitions} ->
        case ModelResolvers.select_process(definitions) do
          {:ok, process} -> [{path, process, definitions}]
          _error -> []
        end

      _error ->
        []
    end
  end

  defp walk_flow_node_ids(flow_nodes, parent_id) do
    Enum.flat_map(flow_nodes, fn flow_node ->
      here = [{flow_node.id, flow_node.type, parent_id}]

      case flow_node.type_data do
        %Model.FlowNodeData.SubProcess{flow_nodes: nested} ->
          here ++ walk_flow_node_ids(nested, flow_node.id)

        _other ->
          here
      end
    end)
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
