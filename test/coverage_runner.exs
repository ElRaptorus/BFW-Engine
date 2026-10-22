# Coverage Runner
#
# Runs integration + conformance tests under a SINGLE :cover session
# and exports the combined .coverdata for merging into the ExCoveralls
# report via `--import-cover cover`.
#
# Used by `mix test.coverdata` (quality alias and CI). For standalone runs
# without coverage overhead, use `mix test.integration` / `mix test.conformance`.

original_logger_level = Logger.level()
Logger.configure(level: :critical)

{:ok, _} = BfwEngine.Persistence.Partitions.ensure_partitions()

support_dir = Path.expand("support", __DIR__)

support_files =
  support_dir
  |> Path.join("*.ex")
  |> Path.wildcard()

for file <- support_files do
  Code.require_file(file)
end

# --- Start cover once for both suites -----------------------------------------
cover_dir = Path.expand("../cover", __DIR__)
File.mkdir_p!(cover_dir)

IO.puts("\n\e[36m▶ Instrumenting beam files for coverage tracking …\e[0m")
:cover.start()

ebin_dir = Path.join(["_build", "test", "lib", "bfw_engine", "ebin"])

# `:cover.compile_beam_directory` rewrites every module in memory.
# Instrumenting `BfwEngine.Expressions.Nif` drops the Rustler on_load
# hook, so `Nif.compile/2` becomes undefined and FEEL/DMN deploys fatal
# (see common-pitfalls.md P79). Skip that beam; leave the loaded NIF.
feel_nif_beam = "Elixir.BfwEngine.Expressions.Nif.beam"

for entry <- File.ls!(ebin_dir),
    String.ends_with?(entry, ".beam"),
    entry != feel_nif_beam do
  :cover.compile_beam(String.to_charlist(Path.join(ebin_dir, entry)))
end

IO.puts("\e[36m  #{ebin_dir} instrumented.\e[0m\n")

# --- Integration tests --------------------------------------------------------
IO.puts("\e[36m▶ Running integration tests …\e[0m\n")
ExUnit.start(autorun: false, trace: true, exclude: [release: true])

integration_dir = Path.expand("integration", __DIR__)

for file <- Path.wildcard(Path.join(integration_dir, "**/*_test.exs")) do
  Code.require_file(file)
end

%{failures: integration_failures} = ExUnit.run()

if integration_failures > 0 do
  IO.puts("\n\e[31m✗ #{integration_failures} integration test failure(s). Aborting.\e[0m")
  :cover.stop()
  System.halt(1)
end

# --- Conformance tests --------------------------------------------------------
IO.puts("\n\e[36m▶ Running conformance tests …\e[0m\n")
ExUnit.configure(seed: :os.system_time(:microsecond))

conformance_dir = Path.expand("conformance", __DIR__)

for file <- Path.wildcard(Path.join(conformance_dir, "**/*_test.exs")) do
  Code.require_file(file)
end

%{failures: conformance_failures} = ExUnit.run()

if conformance_failures > 0 do
  IO.puts("\n\e[31m✗ #{conformance_failures} conformance test failure(s). Aborting.\e[0m")
  :cover.stop()
  System.halt(1)
end

# --- Export combined coverage -------------------------------------------------
IO.puts("\n\e[36m▶ Exporting coverage data to cover/integration.coverdata …\e[0m")
:cover.export(String.to_charlist(Path.join(cover_dir, "integration.coverdata")))
:cover.stop()

# Restore logger level so subsequent mix alias steps (coveralls.html / coveralls) see correct level
Logger.configure(level: original_logger_level)
