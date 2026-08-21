#!/usr/bin/env elixir
# Usage: mix run scripts/generate-parser-snapshots.exs
#
# Walks BPMN fixture directories, parses each file with
# EvilEngine.BPMN.Parser.parse/1, and writes camelCase JSON snapshots
# to packages/js/sdk/test/conformance/snapshots/.
#
# Snapshots whose fixture no longer exists are deleted, so the output
# directory always mirrors the fixture corpus exactly. The conformance suite
# asserts every snapshot it finds; a stale one would be compared against a
# fixture that is gone.
#
# Re-run whenever the engine parser changes.

defmodule SnapshotGenerator do
  @fixture_dirs [
    "test/fixtures/bpmns",
    "apps/core_bpmn/test/fixtures/bpmns"
  ]

  @output_dir "packages/js/sdk/test/conformance/snapshots"

  def run do
    File.mkdir_p!(@output_dir)

    bpmn_files = collect_bpmn_files()

    IO.puts("Found #{length(bpmn_files)} BPMN fixtures")

    {ok, errors} =
      Enum.reduce(bpmn_files, {0, 0}, fn path, {ok_count, err_count} ->
        case process_file(path) do
          :ok -> {ok_count + 1, err_count}
          :error -> {ok_count, err_count + 1}
        end
      end)

    pruned = prune_orphaned_snapshots(bpmn_files)

    IO.puts(
      "\nDone: #{ok} snapshots written, #{errors} parse errors (skipped), #{pruned} orphans pruned"
    )
  end

  # Only top-level `*.json` — `snapshots/dmn/` is owned by the DMN generator.
  defp prune_orphaned_snapshots(bpmn_files) do
    expected = MapSet.new(bpmn_files, &Path.basename(&1, ".bpmn"))

    @output_dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.reject(&MapSet.member?(expected, Path.basename(&1, ".json")))
    |> Enum.map(fn orphan ->
      IO.puts("  Pruning orphaned snapshot: #{Path.basename(orphan)}")
      File.rm!(orphan)
    end)
    |> length()
  end

  defp collect_bpmn_files do
    @fixture_dirs
    |> Enum.flat_map(fn dir ->
      if File.dir?(dir) do
        Path.wildcard(Path.join(dir, "**/*.bpmn"))
      else
        IO.puts("  Skipping #{dir} (not found)")
        []
      end
    end)
    |> Enum.sort()
    |> Enum.uniq_by(&Path.basename/1)
  end

  defp process_file(path) do
    basename = Path.basename(path, ".bpmn")
    xml = File.read!(path)

    case EvilEngine.BPMN.Parser.parse(xml) do
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
    |> Map.delete(:raw_xml)
    |> Enum.map(fn {k, v} -> {camelize(k), to_serializable(v)} end)
    |> Map.new()
  end

  defp to_serializable(list) when is_list(list) do
    Enum.map(list, &to_serializable/1)
  end

  defp to_serializable(%{} = map) when not is_struct(map) do
    Map.new(map, fn {k, v} -> {k, to_serializable(v)} end)
  end

  defp to_serializable(other), do: other

  defp camelize(key) when is_atom(key), do: key |> Atom.to_string() |> camelize()

  defp camelize(key) when is_binary(key) do
    case String.split(key, "_") do
      [single] -> single
      [head | rest] -> head <> Enum.map_join(rest, &String.capitalize/1)
    end
  end
end

SnapshotGenerator.run()
