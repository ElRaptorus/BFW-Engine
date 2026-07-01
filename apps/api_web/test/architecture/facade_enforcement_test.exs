defmodule EvilEngineWeb.Architecture.FacadeEnforcementTest do
  @moduledoc """
  Static-analysis test ensuring that api_web code never calls Ash
  resources directly. All data access must go through EvilEngine.Api.

  This is a file-scan test, not a runtime check.
  """

  use ExUnit.Case, async: true

  @api_web_lib Path.expand("../../../lib", __DIR__)

  @forbidden_patterns [
    ~r/Ash\.(read|read!|read_one|read_one!|get|get!|create|create!|update|update!|bulk_update|destroy|destroy!|Query|Changeset)/
  ]

  @allowed_files [
    "endpoint.ex"
  ]

  test "api_web lib files do not call Ash resources directly" do
    violations =
      @api_web_lib
      |> list_ex_files()
      |> Enum.reject(&allowed_file?/1)
      |> Enum.flat_map(&scan_file/1)

    if violations != [] do
      message =
        [
          "Facade violation: api_web code must not call Ash directly. Use EvilEngine.Api instead.\n"
          | Enum.map(violations, fn {file, line_no, line} ->
              "  #{Path.relative_to(file, @api_web_lib)}:#{line_no}: #{String.trim(line)}"
            end)
        ]
        |> Enum.join("\n")

      flunk(message)
    end
  end

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
      if Enum.any?(@forbidden_patterns, &Regex.match?(&1, line)) do
        [{path, line_no, line}]
      else
        []
      end
    end)
  end
end
