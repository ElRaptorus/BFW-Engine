# Load / Benchmark Test Runner
#
# Boots ExUnit, compiles root-level support modules, and runs all
# `test/load/**/*_test.exs` files against the fully started umbrella.
#
# NOT included in `mix quality` or `mix test.full` — load tests are
# opt-in, run explicitly by developers or a separate CI job.
#
# Usage:
#   MIX_ENV=test mix run test/load_runner.exs
#
# Or through the mix alias:
#   mix test.load
#
# Optional subset (same argv pattern as test/integration_runner.exs):
#   MIX_ENV=test mix run test/load_runner.exs -- load/benchmark_reporter_test.exs

Logger.configure(level: :warning)

support_dir = Path.expand("support", __DIR__)

for file <- Path.wildcard(Path.join(support_dir, "*.ex")) do
  Code.require_file(file)
end

{:ok, _} = EvilEngine.Test.BenchmarkReporter.start_link()

ExUnit.start(autorun: false, trace: true, timeout: 300_000)

relative_test_trees =
  case System.argv() |> Enum.reject(&(&1 == "--")) do
    [] -> ["load"]
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

EvilEngine.Test.LoadRunnerReport.finish!(failures)
