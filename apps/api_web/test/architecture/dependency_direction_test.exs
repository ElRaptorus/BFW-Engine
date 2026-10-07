defmodule BfwEngineWeb.Architecture.DependencyDirectionTest do
  @moduledoc """
  Static check of the umbrella dependency graph, `Mix.env` in library
  code, and grab-bag module names.

  `mix.exs` deps are the graph. Elixir already warns when code calls
  into an undeclared umbrella app. This test checks that the declared
  graph matches the layer rules.
  """

  use ExUnit.Case, async: true

  @apps_directory Path.expand("../../../../apps", __DIR__)

  @core [
    :core_types,
    :core_execution,
    :core_events,
    :core_timers,
    :core_expressions,
    :core_bpmn,
    :core_dmn,
    :engine_sdk
  ]

  @peripheral [:peripheral_persistence, :peripheral_telemetry]
  @plugins [:engine_plugins]
  @api [:api_auth, :api_facade, :api_web]

  @explicit_edges [
    {:api_web, :engine_plugins},
    {:peripheral_telemetry, :engine_plugins}
  ]

  @mix_env_allowlist [
    "peripheral_persistence/lib/bfw_engine/persistence/repo_router.ex",
    "engine_sdk/lib/mix/tasks/bfw.gen.plugin.ex"
  ]

  @forbidden_suffixes ["Helpers", "Utils", "Util", "Common", "Misc"]

  test "umbrella edges stay inside the layer rules" do
    applications = list_applications()

    missing =
      Enum.reject(applications, fn {application, _edges} ->
        application in (@core ++ @peripheral ++ @plugins ++ @api)
      end)

    violations =
      Enum.flat_map(applications, fn {source_application, target_applications} ->
        Enum.flat_map(target_applications, fn target_application ->
          if allowed_edge?(source_application, target_application) do
            []
          else
            ["#{source_application} → #{target_application}"]
          end
        end)
      end)

    messages =
      Enum.map(missing, fn {application, _} ->
        "#{application} is not in the layer table"
      end) ++ violations

    if messages != [] do
      flunk(Enum.join(["Dependency direction violations:" | messages], "\n"))
    end
  end

  test "Mix.env in lib is limited to the allowlist" do
    violations =
      @apps_directory
      |> Path.join("*/lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(&allowlisted_mix_env_file?/1)
      |> Enum.flat_map(&mix_env_lines/1)

    if violations != [] do
      flunk(Enum.join(["Mix.env in lib/:" | violations], "\n"))
    end
  end

  test "library modules are not named Helpers, Utils, Util, Common, or Misc" do
    violations =
      @apps_directory
      |> Path.join("*/lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(&forbidden_module_names/1)

    if violations != [] do
      flunk(Enum.join(["Forbidden module names:" | violations], "\n"))
    end
  end

  defp list_applications do
    @apps_directory
    |> Path.join("*/mix.exs")
    |> Path.wildcard()
    |> Enum.map(fn mix_file ->
      application = mix_file |> Path.dirname() |> Path.basename() |> String.to_atom()
      {application, umbrella_dependencies(File.read!(mix_file))}
    end)
  end

  defp umbrella_dependencies(contents) do
    Regex.scan(~r/\{:(\w+),[^}]*\bin_umbrella:\s*true/, contents)
    |> Enum.map(fn [_match, application] -> String.to_atom(application) end)
  end

  defp allowed_edge?(_source_application, :api_web), do: false

  defp allowed_edge?(source_application, target_application) do
    explicit_edge?(source_application, target_application) or
      core_edge?(source_application, target_application) or
      peripheral_edge?(source_application, target_application) or
      plugin_edge?(source_application, target_application) or
      api_edge?(source_application, target_application)
  end

  defp explicit_edge?(source_application, target_application) do
    {source_application, target_application} in @explicit_edges
  end

  defp core_edge?(source_application, target_application) do
    source_application in @core and target_application in @core
  end

  defp peripheral_edge?(source_application, target_application) do
    source_application in @peripheral and
      (target_application in @core or target_application in @peripheral)
  end

  defp plugin_edge?(source_application, target_application) do
    source_application in @plugins and
      (target_application in @core or target_application == :api_facade)
  end

  defp api_edge?(source_application, target_application) do
    source_application in @api and
      (target_application in @core or target_application in @peripheral or
         target_application in @api)
  end

  defp allowlisted_mix_env_file?(path) do
    relative = Path.relative_to(path, @apps_directory)
    relative in @mix_env_allowlist
  end

  defp mix_env_lines(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_number} ->
      if String.contains?(line, "Mix.env") do
        ["#{Path.relative_to(path, @apps_directory)}:#{line_number}: #{String.trim(line)}"]
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
      ["#{Path.relative_to(path, @apps_directory)}:#{line_number}: #{module_name}"]
    else
      []
    end
  end
end
