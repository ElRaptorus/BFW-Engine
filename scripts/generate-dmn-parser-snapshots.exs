#!/usr/bin/env elixir
# Usage: mix run scripts/generate-dmn-parser-snapshots.exs
#
# Walks DMN fixture directories, parses each file with
# BfwEngine.DMN.Parser.parse/1, and writes camelCase JSON snapshots
# to packages/js/sdk/test/conformance/snapshots/dmn/.
#
# Re-run whenever the engine DMN parser changes.

defmodule DmnSnapshotGenerator do
  @fixture_dirs [
    "apps/core_dmn/test/fixtures/dmns"
  ]

  @output_dir "packages/js/sdk/test/conformance/snapshots/dmn"

  @hit_policy_map %{
    unique: "unique",
    first: "first",
    any: "any",
    collect: "collect",
    rule_order: "rule_order",
    output_order: "output_order",
    priority: "priority"
  }

  @aggregation_map %{
    sum: "SUM",
    min: "MIN",
    max: "MAX",
    count: "COUNT"
  }

  @orientation_map %{
    rule_as_row: "Rule-as-Row",
    rule_as_column: "Rule-as-Column",
    cross_table: "CrossTable"
  }

  @kind_map %{
    feel: "FEEL",
    java: "Java",
    pmml: "PMML",
    unsupported: "unsupported"
  }

  @strip_keys [:raw_xml, :compiled_ref, :compiled_expression_ref]

  def run do
    File.mkdir_p!(@output_dir)

    dmn_files = collect_dmn_files()

    IO.puts("Found #{length(dmn_files)} DMN fixtures")

    {ok, errors} =
      Enum.reduce(dmn_files, {0, 0}, fn path, {ok_count, err_count} ->
        case process_file(path) do
          :ok -> {ok_count + 1, err_count}
          :error -> {ok_count, err_count + 1}
        end
      end)

    IO.puts("\nDone: #{ok} snapshots written, #{errors} parse errors (skipped)")
  end

  defp collect_dmn_files do
    @fixture_dirs
    |> Enum.flat_map(fn dir ->
      if File.dir?(dir) do
        Path.wildcard(Path.join(dir, "**/*.dmn"))
      else
        IO.puts("  Skipping #{dir} (not found)")
        []
      end
    end)
    |> Enum.sort()
    |> Enum.uniq_by(&Path.basename/1)
  end

  defp process_file(path) do
    basename = Path.basename(path, ".dmn")
    xml = File.read!(path)

    case BfwEngine.DMN.Parser.parse(xml) do
      {:ok, definitions} ->
        json =
          definitions
          |> to_serializable()
          |> Jason.encode!(pretty: true)

        out_path = Path.join(@output_dir, "#{basename}.json")
        File.write!(out_path, json <> "\n")
        IO.puts("  #{basename}.json")
        :ok

      {:error, reason} ->
        IO.puts("  SKIP #{basename} — parse error: #{inspect(reason)}")
        :error
    end
  end

  defp to_serializable(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> strip_internal_keys()
    |> Enum.map(fn {key, value} -> {camelize(key), convert_value(key, value)} end)
    |> Map.new()
  end

  defp to_serializable(list) when is_list(list) do
    Enum.map(list, &to_serializable/1)
  end

  defp to_serializable(%{} = map) when not is_struct(map) do
    Map.new(map, fn {key, value} -> {key, to_serializable(value)} end)
  end

  defp to_serializable(other), do: other

  defp strip_internal_keys(map) do
    Map.drop(map, @strip_keys)
  end

  defp convert_value(:hit_policy, atom) when is_atom(atom) do
    Map.get(@hit_policy_map, atom, Atom.to_string(atom))
  end

  defp convert_value(:aggregation, nil), do: nil

  defp convert_value(:aggregation, atom) when is_atom(atom) do
    Map.get(@aggregation_map, atom, Atom.to_string(atom))
  end

  defp convert_value(:preferred_orientation, atom) when is_atom(atom) do
    Map.get(@orientation_map, atom, Atom.to_string(atom))
  end

  defp convert_value(:kind, atom) when is_atom(atom) do
    Map.get(@kind_map, atom, Atom.to_string(atom))
  end

  defp convert_value(:is_collection, value), do: value

  defp convert_value(_key, value), do: to_serializable(value)

  defp camelize(key) when is_atom(key), do: key |> Atom.to_string() |> camelize()

  defp camelize(key) when is_binary(key) do
    case String.split(key, "_") do
      [single] -> single
      [head | rest] -> head <> Enum.map_join(rest, &String.capitalize/1)
    end
  end
end

DmnSnapshotGenerator.run()
