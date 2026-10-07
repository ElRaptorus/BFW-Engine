# Integration Test Runner
#
# Boots ExUnit, compiles root-level support modules, and runs all
# `test/integration/**/*_test.exs` files against the fully started umbrella.
#
# Usage:
#   MIX_ENV=test mix run test/integration_runner.exs
#
# Or through the mix alias:
#   mix test.integration

Logger.configure(level: :critical)

{:ok, _} = BfwEngine.Persistence.Partitions.ensure_partitions()

support_dir = Path.expand("support", __DIR__)

support_files =
  support_dir
  |> Path.join("*.ex")
  |> Path.wildcard()
  |> Enum.sort_by(&(Path.basename(&1) != "service_reset.ex"))

for file <- support_files do
  Code.require_file(file)
end

ex_unit_options =
  if System.get_env("BFE_TEST_RELEASE") == "1" do
    [autorun: false, trace: true]
  else
    [autorun: false, trace: true, exclude: [release: true]]
  end

ExUnit.start(ex_unit_options)

relative_test_trees =
  case System.argv() |> Enum.reject(&(&1 == "--")) do
    [] -> ["integration"]
    relative_paths -> relative_paths
  end

test_files =
  relative_test_trees
  |> Enum.flat_map(fn relative_path ->
    test_path = Path.expand(relative_path, __DIR__)

    cond do
      File.regular?(test_path) ->
        [test_path]

      File.dir?(test_path) ->
        Path.wildcard(Path.join(test_path, "**/*_test.exs"))

      true ->
        []
    end
  end)
  |> Enum.uniq()

for file <- test_files do
  Code.require_file(file)
end

%{failures: failures} = ExUnit.run()

if failures > 0 do
  IO.puts("\n\e[31m✗ #{failures} integration test failure(s). Aborting.\e[0m")
  System.halt(1)
end
