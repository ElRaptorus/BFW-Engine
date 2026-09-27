defmodule BfwEngine.Execution.Architecture.TaskInboxEventsEnforcementTest do
  @moduledoc """
  Static-analysis test ensuring `core_execution` never publishes
  `%Event.FlowNodeInstanceFinished{}` directly on the `EngineEventBus`.

  D3 requires a single emission point:
  `BfwEngine.Execution.TaskInboxEvents.publish_flow_node_instance_finished/2`.
  Every other call site must route through it so `UserTaskFinished` is
  derived consistently for every path that ends an inbox task.

  This is a file-scan test, not a runtime check. A string scan catches the
  fully qualified call, and an AST walk catches the same call through an alias.
  """

  use ExUnit.Case, async: true

  @core_execution_lib Path.expand("../../lib", __DIR__)

  @forbidden_pattern ~r/EngineEventBus\.publish\(%Event\.FlowNodeInstanceFinished\{/

  @allowed_files [
    "task_inbox_events.ex"
  ]

  test "core_execution lib files do not publish FlowNodeInstanceFinished directly" do
    violations =
      @core_execution_lib
      |> list_ex_files()
      |> Enum.reject(&allowed_file?/1)
      |> Enum.flat_map(&scan_file/1)

    if violations != [] do
      message =
        [
          "Task inbox violation: FlowNodeInstanceFinished must be published through " <>
            "TaskInboxEvents.publish_flow_node_instance_finished/2, not directly.\n"
          | Enum.map(violations, fn {file, line_no, line} ->
              "  #{Path.relative_to(file, @core_execution_lib)}:#{line_no}: #{String.trim(line)}"
            end)
        ]
        |> Enum.join("\n")

      flunk(message)
    end
  end

  test "an AST walk rejects an aliased EngineEventBus.publish of FlowNodeInstanceFinished" do
    violations =
      @core_execution_lib
      |> list_ex_files()
      |> Enum.reject(&allowed_file?/1)
      |> Enum.flat_map(&ast_violations/1)

    if violations != [] do
      flunk(
        "Task inbox violation: FlowNodeInstanceFinished must be published through " <>
          "TaskInboxEvents.publish_flow_node_instance_finished/2.\n" <>
          Enum.join(violations, "\n")
      )
    end
  end

  test "the walker fails on an aliased publish and passes on TaskInboxEvents" do
    aliased = """
    defmodule Example do
      alias BfwEngine.Events.EngineEventBus, as: Bus

      def bad do
        Bus.publish(%BfwEngine.Types.Event.FlowNodeInstanceFinished{})
      end
    end
    """

    allowed = """
    defmodule Example do
      alias BfwEngine.Execution.TaskInboxEvents

      def good(event) do
        TaskInboxEvents.publish_flow_node_instance_finished(event)
      end
    end
    """

    assert direct_finished_publish?(aliased)
    refute direct_finished_publish?(allowed)
  end

  defp ast_violations(path) do
    if direct_finished_publish?(File.read!(path)) do
      [Path.relative_to(path, @core_execution_lib)]
    else
      []
    end
  end

  defp direct_finished_publish?(source) do
    quoted = Code.string_to_quoted!(source)
    aliases = collect_aliases(quoted)

    {_, found} =
      Macro.prewalk(quoted, false, fn
        {{:., _, [{:__aliases__, _, name_parts}, :publish]}, _, [first_argument | _]}, found ->
          resolved = resolve_alias(name_parts, aliases)

          if List.last(resolved) == :EngineEventBus and finished_struct?(first_argument) do
            {first_argument, true}
          else
            {first_argument, found}
          end

        node, found ->
          {node, found}
      end)

    found
  end

  defp collect_aliases(quoted) do
    {_, aliases} =
      Macro.prewalk(quoted, %{}, fn
        {:alias, _, [{:__aliases__, _, parts} | options]}, aliases ->
          local_name =
            case options do
              [[as: {:__aliases__, _, [as_name]}]] -> as_name
              _ -> List.last(parts)
            end

          {parts, Map.put(aliases, local_name, parts)}

        node, aliases ->
          {node, aliases}
      end)

    aliases
  end

  defp resolve_alias([local_name | rest], aliases) do
    case Map.fetch(aliases, local_name) do
      {:ok, parts} -> parts ++ rest
      :error -> [local_name | rest]
    end
  end

  defp finished_struct?({:%, _, [{:__aliases__, _, parts}, _fields]}) do
    List.last(parts) == :FlowNodeInstanceFinished
  end

  defp finished_struct?(_other), do: false

  defp list_ex_files(dir) do
    dir
    |> Path.join("**/*.ex")
    |> Path.wildcard()
  end

  defp allowed_file?(path) do
    basename = Path.basename(path)
    basename in @allowed_files
  end

  defp scan_file(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_no} ->
      if Regex.match?(@forbidden_pattern, line) do
        [{path, line_no, line}]
      else
        []
      end
    end)
  end
end
