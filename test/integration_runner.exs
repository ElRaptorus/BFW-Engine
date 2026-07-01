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

test_dir = Path.expand("integration", __DIR__)

for file <- Path.wildcard(Path.join(test_dir, "**/*_test.exs")) do
  Code.require_file(file)
end

%{failures: failures} = ExUnit.run()

if failures > 0 do
  IO.puts("\n\e[31m✗ #{failures} integration test failure(s). Aborting.\e[0m")
  System.halt(1)
end
