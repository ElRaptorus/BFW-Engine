defmodule BfwEngine.Architecture.LibraryConventionsTest do
  @moduledoc """
  Static check of `Mix.env` in library code and of grab-bag module names.

  The layer rules between namespaces are enforced at compile time by the
  `boundary` compiler (`use Boundary` in each top-level namespace module).
  """

  use ExUnit.Case, async: true

  @lib_directory Path.expand("../../../lib", __DIR__)

  @mix_env_allowlist [
    "bfw_engine/persistence/repo_router.ex",
    "mix/tasks/bfw.gen.plugin.ex"
  ]

  @forbidden_suffixes ["Helpers", "Utils", "Util", "Common", "Misc"]

  test "Mix.env in lib is limited to the allowlist" do
    violations =
      library_files()
      |> Enum.reject(&(Path.relative_to(&1, @lib_directory) in @mix_env_allowlist))
      |> Enum.flat_map(&mix_env_lines/1)

    if violations != [] do
      flunk(Enum.join(["Mix.env in lib/:" | violations], "\n"))
    end
  end

  test "library modules are not named Helpers, Utils, Util, Common, or Misc" do
    violations = Enum.flat_map(library_files(), &forbidden_module_names/1)

    if violations != [] do
      flunk(Enum.join(["Forbidden module names:" | violations], "\n"))
    end
  end

  defp library_files do
    @lib_directory
    |> Path.join("**/*.ex")
    |> Path.wildcard()
  end

  defp mix_env_lines(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_number} ->
      if String.contains?(line, "Mix.env") do
        ["#{Path.relative_to(path, @lib_directory)}:#{line_number}: #{String.trim(line)}"]
      else
        []
      end
    end)
  end

  defp forbidden_module_names(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(&forbidden_name_on_line(path, &1))
  end

  defp forbidden_name_on_line(path, {line, line_number}) do
    case Regex.run(~r/defmodule\s+([\w.]+)/, line) do
      [_match, module_name] -> forbidden_suffix_message(path, line_number, module_name)
      _ -> []
    end
  end

  defp forbidden_suffix_message(path, line_number, module_name) do
    last_segment = module_name |> String.split(".") |> List.last()

    if Enum.any?(@forbidden_suffixes, &String.ends_with?(last_segment, &1)) do
      ["#{Path.relative_to(path, @lib_directory)}:#{line_number}: #{module_name}"]
    else
      []
    end
  end
end
