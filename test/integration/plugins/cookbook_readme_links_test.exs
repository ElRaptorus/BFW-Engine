defmodule BfwEngine.Integration.CookbookReadmeLinksTest do
  @moduledoc """
  Acceptance (iii): cookbook Markdown files must not point at missing local
  `.md`, `.ex`, or `.bpmn` paths. External `http(s)` URLs are skipped so CI
  does not flake on GitHub.
  """

  use BfwEngine.IntegrationCase, async: false

  @examples_root Path.expand("../../../examples", __DIR__)
  @markdown_link_pattern ~r/\[[^\]]*\]\(([^)]+)\)/
  @checked_extensions MapSet.new([".md", ".ex", ".exs", ".bpmn", ".dmn"])

  test "relative markdown, elixir, and bpmn links in examples resolve" do
    markdown_paths =
      @examples_root
      |> Path.join("**/*.md")
      |> Path.wildcard()
      |> Enum.reject(&path_has_ignored_segment?/1)
      |> Enum.sort()

    assert markdown_paths != []

    missing =
      Enum.flat_map(markdown_paths, fn markdown_path ->
        markdown_path
        |> File.read!()
        |> then(&Regex.scan(@markdown_link_pattern, &1, capture: :all_but_first))
        |> List.flatten()
        |> Enum.flat_map(&missing_local_target(markdown_path, &1))
      end)

    assert missing == [], """
    Broken cookbook links:
    #{Enum.map_join(missing, "\n", fn {source, target} -> "  #{source} -> #{target}" end)}
    """
  end

  defp path_has_ignored_segment?(path) do
    Enum.any?(Path.split(path), &(&1 in ["node_modules", "deps", "_build"]))
  end

  defp missing_local_target(markdown_path, raw_target) do
    trimmed = String.trim(raw_target)

    cond do
      trimmed == "" ->
        []

      String.starts_with?(trimmed, ["http://", "https://", "mailto:", "#"]) ->
        []

      true ->
        path_without_anchor = trimmed |> String.split("#", parts: 2) |> hd()

        if path_without_anchor == "" do
          []
        else
          resolved = Path.expand(path_without_anchor, Path.dirname(markdown_path))

          if path_has_ignored_segment?(resolved) do
            []
          else
            extension = Path.extname(resolved)

            should_check? =
              File.dir?(resolved) or extension == "" or
                MapSet.member?(@checked_extensions, extension)

            if should_check? and not File.exists?(resolved) do
              [{Path.relative_to(markdown_path, @examples_root), trimmed}]
            else
              []
            end
          end
        end
    end
  end
end
