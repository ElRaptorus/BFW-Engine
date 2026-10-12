defmodule Mix.Tasks.Bfw.Gen.Contracts do
  @moduledoc """
  Exports the GraphQL SDL and the OpenAPI document to `contracts/`.

  ## Usage

      mix bfw.gen.contracts
      mix bfw.gen.contracts --check

  `--check` (`-c`) regenerates in memory and compares against the committed
  files without writing, exiting non-zero on drift. It is part of `mix quality`.

  ## Output paths

    * `contracts/graphql/schema.graphql`
    * `contracts/openapi.json`

  Other engines (BFW-Engine-Lite) vendor these files and test against them.
  """

  use Mix.Task

  alias BfwEngineWeb.ContractExport

  @shortdoc "Export the GraphQL SDL and OpenAPI JSON to contracts/"

  @switches [check: :boolean, help: :boolean]
  @aliases [c: :check, h: :help]

  @impl Mix.Task
  def run(arguments) do
    {options, _rest, _invalid} =
      OptionParser.parse(arguments, strict: @switches, aliases: @aliases)

    Mix.Task.run("app.config")

    cond do
      Keyword.get(options, :help, false) -> Mix.shell().info(@moduledoc)
      Keyword.get(options, :check, false) -> check()
      true -> generate()
    end
  end

  defp generate do
    Enum.each(ContractExport.render_all(), fn {path, content} ->
      full_path = repository_path(path)
      full_path |> Path.dirname() |> File.mkdir_p!()
      File.write!(full_path, content)
      Mix.shell().info("Wrote #{path}")
    end)
  end

  defp check do
    drifted_paths =
      for {path, content} <- ContractExport.render_all(),
          not File.exists?(repository_path(path)) or File.read!(repository_path(path)) != content,
          do: path

    if drifted_paths == [] do
      Mix.shell().info("contracts/ is up to date.")
    else
      Mix.shell().error(
        "contracts/ is out of date. Run `mix bfw.gen.contracts` and commit the result. Drifted paths:\n" <>
          Enum.map_join(drifted_paths, "\n", &"  - #{&1}")
      )

      exit({:shutdown, 1})
    end
  end

  defp repository_path(path) do
    Mix.Project.deps_path() |> Path.dirname() |> Path.join(path)
  end
end
