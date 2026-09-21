# Load / Benchmark Test Runner
#
# Boots ExUnit, compiles root-level support modules, and runs all
# `test/load/**/*_test.exs` files against the fully started umbrella.
#
# NOT included in `mix quality` or `mix test.full` — load tests are
# opt-in, run explicitly by developers or a separate CI job.
#
# Usage:
#   mix test.load
#   mix test.load.durability
#   mix test.load.hardening
#   mix test.load.all
#
# The alias sets BFE_LOAD_TEST_POOL=1 (real DBConnection.ConnectionPool).
# Do not run this file under the Ecto sandbox — E8 exceeds ownership_timeout
# and then every in-flight PI logs OwnershipError (P89).
#
# Durability tests (20k / 50k / 100k HTTP execution) are tagged
# `:durability` and excluded by default.
#   mix test.load.durability  → BFE_LOAD_DURABILITY=1  (that file only)
#   mix test.load.all         → BFE_LOAD_DURABILITY=all + BFE_LOAD_HARDENING=all
#                               (default suite + durability + hardening)
# One JSON report either way. Not for GitHub ubuntu-latest — a 100k mixed
# run is ~1 hour on that runner.
#
# Hardening tests (LZ4 vs PGLZ, payload-cap chaos, resume-crash) are tagged
# `:hardening` and excluded from mix test.load (and GitHub load-bench).
#   mix test.load.hardening   → BFE_LOAD_HARDENING=1  (hardening files only)
#   mix test.load.all         → includes hardening with durability
#   BFE_LOAD_HARDENING=all    → default suite + hardening (still excludes durability
#                               unless BFE_LOAD_DURABILITY=all)
#
# Optional subset (same argv pattern as test/integration_runner.exs):
#   BFE_LOAD_TEST_POOL=1 MIX_ENV=test mix run test/load_runner.exs -- load/benchmark_reporter_test.exs

Logger.configure(level: :warning)

support_dir = Path.expand("support", __DIR__)

for file <- Path.wildcard(Path.join(support_dir, "*.ex")) do
  Code.require_file(file)
end

if BfwEngine.Test.DbAssertions.sandbox_pool?() do
  IO.puts(:stderr, """
  [load] WARNING: Repo is still Ecto.Adapters.SQL.Sandbox.
  E8 can exceed ownership_timeout (300s) and cascade OwnershipError (P89).
  Run via `mix test.load` so BFE_LOAD_TEST_POOL=1 is set before Mix starts.
  """)
end

{:ok, _} = BfwEngine.Test.BenchmarkReporter.start_link()

durability_mode = System.get_env("BFE_LOAD_DURABILITY")
durability_only? = durability_mode in ["1", "true"]
include_durability? = durability_only? or durability_mode == "all"

hardening_mode = System.get_env("BFE_LOAD_HARDENING")
hardening_only? = hardening_mode in ["1", "true"]
include_hardening? = hardening_only? or hardening_mode == "all"

exunit_opts =
  cond do
    hardening_only? ->
      IO.puts("[load] Hardening suite only (LZ4 vs PGLZ, payload-cap chaos, resume-crash).")
      [autorun: false, trace: true, timeout: 300_000, include: [:hardening], exclude: [:test]]

    durability_only? ->
      IO.puts("[load] Durability suite only (20k / 50k / 100k per shape). This can take hours.")
      [autorun: false, trace: true, timeout: 300_000, include: [:durability], exclude: [:test]]

    true ->
      excludes =
        Enum.reject([:durability, :hardening], fn tag ->
          (tag == :durability and include_durability?) or
            (tag == :hardening and include_hardening?)
        end)

      cond do
        include_durability? and include_hardening? ->
          IO.puts("[load] Default suite + durability + hardening. This can take hours.")

        include_durability? ->
          IO.puts(
            "[load] Default suite + durability (20k / 50k / 100k per shape). This can take hours."
          )

        include_hardening? ->
          IO.puts("[load] Default suite + hardening (LZ4 vs PGLZ, chaos, resume-crash).")

        true ->
          :ok
      end

      [autorun: false, trace: true, timeout: 300_000, exclude: excludes]
  end

ExUnit.start(exunit_opts)

relative_test_trees =
  case System.argv() |> Enum.reject(&(&1 == "--")) do
    [] when durability_only? ->
      ["load/execution_durability_load_test.exs"]

    [] when hardening_only? ->
      [
        "load/jsonb_compression_load_test.exs",
        "load/payload_cap_chaos_load_test.exs",
        "load/resume_crash_load_test.exs"
      ]

    [] ->
      ["load"]

    relative_paths ->
      relative_paths
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

BfwEngine.Test.LoadRunnerReport.finish!(failures)
