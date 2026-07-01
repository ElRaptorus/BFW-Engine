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

Logger.configure(level: :warning)

support_dir = Path.expand("support", __DIR__)

for file <- Path.wildcard(Path.join(support_dir, "*.ex")) do
  Code.require_file(file)
end

ExUnit.start(autorun: false, trace: true, timeout: 300_000)

test_dir = Path.expand("load", __DIR__)

for file <- Path.wildcard(Path.join(test_dir, "**/*_test.exs")) do
  Code.require_file(file)
end

%{failures: failures} = ExUnit.run()

if failures > 0 do
  IO.puts("\n\e[31m✗ #{failures} load test failure(s). Aborting.\e[0m")
  System.halt(1)
end
