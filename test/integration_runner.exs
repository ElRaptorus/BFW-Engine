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

{:ok, _} = EvilEngine.Persistence.Partitions.ensure_partitions()

support_dir = Path.expand("support", __DIR__)

for file <- Path.wildcard(Path.join(support_dir, "*.ex")) do
  Code.require_file(file)
end

ExUnit.start(autorun: false, trace: true)

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
