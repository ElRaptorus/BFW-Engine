defmodule Mix.Tasks.Bfw.Gen.ExtensionManifest do
  @moduledoc """
  Generate `extension-manifest.json` from `BfwEngine.BPMN.ExtensionManifest`
  (Phase 6.1, WP-5). Replaces the cancelled `mix bfw.gen.moddle_descriptor`
  — see the plan's D-5 for why the Engine ships a vocabulary manifest
  instead of a generated moddle descriptor.

  ## Usage

      mix bfw.gen.extension_manifest
      mix bfw.gen.extension_manifest --check

  `--check` (`-c`) regenerates in memory and diffs against every configured
  output path without writing, exiting non-zero on drift. Used as the CI
  diff-guard (WP-5.3): a manifest that no longer matches its committed
  copies means someone edited the JSON by hand, or forgot to regenerate
  after changing `ExtensionManifest`.

  ## Output paths

  Writes two identical copies, both intended to be committed:

    * `extension-manifest.json` (repo root — canonical, engine-owned copy)
    * `packages/js/sdk/src/generated/extension-manifest.json` (shipped in
      `@elraptorus/bfw_engine_sdk`, the contract-layer package, per D-7)
  """

  use Mix.Task

  alias BfwEngine.BPMN.ExtensionManifest

  @shortdoc "Generate extension-manifest.json from ExtensionManifest"

  @switches [check: :boolean, help: :boolean]
  @aliases [c: :check, h: :help]

  @output_paths [
    "extension-manifest.json",
    "packages/js/sdk/src/generated/extension-manifest.json"
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    cond do
      Keyword.get(opts, :help, false) -> Mix.shell().info(@moduledoc)
      Keyword.get(opts, :check, false) -> check()
      true -> generate()
    end
  end

  defp generate do
    json = encode()

    Enum.each(@output_paths, fn path ->
      full_path = root_relative(path)
      full_path |> Path.dirname() |> File.mkdir_p!()
      File.write!(full_path, json)
      Mix.shell().info("Wrote #{path}")
    end)
  end

  defp check do
    json = encode()

    drifted =
      Enum.filter(@output_paths, fn path ->
        full_path = root_relative(path)
        not File.exists?(full_path) or File.read!(full_path) != json
      end)

    if drifted == [] do
      Mix.shell().info(
        "extension-manifest.json is up to date in all #{length(@output_paths)} locations."
      )
    else
      Mix.shell().error(
        "extension-manifest.json is out of date. Run `mix bfw.gen.extension_manifest` and commit the result. Drifted paths:\n" <>
          Enum.map_join(drifted, "\n", &"  - #{&1}")
      )

      exit({:shutdown, 1})
    end
  end

  defp encode do
    ExtensionManifest.to_json()
  end

  defp root_relative(path) do
    Path.join(project_root(), path)
  end

  defp project_root do
    Mix.Project.deps_path() |> Path.dirname()
  end
end
