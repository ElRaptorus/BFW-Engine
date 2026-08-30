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

{:ok, _} = EvilEngine.Persistence.Partitions.ensure_partitions()

support_dir = Path.expand("support", __DIR__)

for file <- Path.wildcard(Path.join(support_dir, "*.ex")) do
  Code.require_file(file)
end

# --- Start cover once for both suites -----------------------------------------
cover_dir = Path.expand("../cover", __DIR__)
File.mkdir_p!(cover_dir)

IO.puts("\n\e[36m▶ Instrumenting beam files for coverage tracking …\e[0m")
:cover.start()

project_apps =
  Path.wildcard("apps/*/mix.exs")
  |> Enum.map(fn path -> path |> Path.dirname() |> Path.basename() end)

ebin_dirs =
  project_apps
  |> Enum.map(&Path.join(["_build", "test", "lib", &1, "ebin"]))
  |> Enum.filter(&File.dir?/1)
  |> Enum.map(&String.to_charlist/1)

# `:cover.compile_beam_directory` rewrites every module in memory.
# Instrumenting `EvilEngine.Expressions.Nif` drops the Rustler on_load
# hook, so `Nif.compile/2` becomes undefined and FEEL/DMN deploys fatal
# (see common-pitfalls.md P79). Skip that beam; leave the loaded NIF.
feel_nif_beam = "Elixir.EvilEngine.Expressions.Nif.beam"

for dir <- ebin_dirs do
  directory = List.to_string(dir)

  case File.ls(directory) do
    {:ok, entries} ->
      if feel_nif_beam in entries do
        for entry <- entries,
            String.ends_with?(entry, ".beam"),
            entry != feel_nif_beam do
          :cover.compile_beam(String.to_charlist(Path.join(directory, entry)))
        end
      else
        :cover.compile_beam_directory(dir)
      end

    {:error, _reason} ->
      :ok
  end
end

IO.puts("\e[36m  #{length(ebin_dirs)} project ebin directories instrumented.\e[0m\n")

# --- Integration tests --------------------------------------------------------
IO.puts("\e[36m▶ Running integration tests …\e[0m\n")
ExUnit.start(autorun: false, trace: true)

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
IO.puts("\n\e[36m▶ Exporting coverage data to cover/umbrella.coverdata …\e[0m")
coverdata_path = Path.join(cover_dir, "umbrella.coverdata")
:cover.export(String.to_charlist(coverdata_path))
:cover.stop()

# ExCoveralls resolves --import-cover relative to each sub-app's CWD
# (apps/<app>/), so we must place coverdata inside each sub-app's cover/ dir.
for app <- project_apps do
  app_cover = Path.join(["apps", app, "cover"])
  File.mkdir_p!(app_cover)
  File.cp!(coverdata_path, Path.join(app_cover, "umbrella.coverdata"))
end

IO.puts("\e[36m  Done — coverdata distributed to #{length(project_apps)} sub-app cover/ directories.\e[0m\n")

# Restore logger level so subsequent mix alias steps (coveralls.html / coveralls) see correct level
Logger.configure(level: original_logger_level)
