defmodule EvilEngine.BPMN.SeedingRunner do
  @moduledoc """
  Boot-time runner that seeds the `ModelCache` from a directory of
  `.bpmn` files.

  Runs once synchronously during application start. One bad file does
  not block boot — it is logged and skipped.

  When the linter gate is configured (`:core_bpmn, :linter_gate`),
  each file is also checked against the gate — unless
  `EVIL_LINTER_GATE_SKIP_SEEDING=true` (`:core_bpmn, :linter_gate,
  :skip_seeding`). Linter gate failures during seeding are logged and
  the file is skipped, never fatal.

  If a catalog persist function is configured (`:core_bpmn,
  :seeding_persist_fn`), the runner also writes `processes` +
  `process_versions` rows to the catalog. This is wired by the
  `peripheral_persistence` app at boot.
  """

  require Logger

  alias EvilEngine.BPMN.LinterGate
  alias EvilEngine.BPMN.ModelCache

  @doc """
  Enumerate `*.bpmn` files in the configured seeding directory,
  parse + validate each, optionally run the linter gate, cache the
  results, and persist to catalog.

  Returns `:ok` (always succeeds — failures are logged, not raised).
  """
  @spec run() :: :ok
  def run do
    case Application.get_env(:core_bpmn, :seeding_directory) do
      nil -> :ok
      "" -> :ok
      dir -> seed_from(dir)
    end
  end

  defp seed_from(dir) do
    if File.dir?(dir) do
      seed_directory(dir)
    else
      Logger.warning("[SeedingRunner] Directory does not exist: #{dir}")
      return_summary(0, 0, 0)
    end
  end

  defp seed_directory(dir) do
    files = Path.wildcard(Path.join(dir, "*.bpmn"))

    {successes, failures} =
      Enum.reduce(files, {0, 0}, fn file, {ok_count, err_count} ->
        case seed_file(file) do
          {:ok, count} -> {ok_count + count, err_count}
          :error -> {ok_count, err_count + 1}
        end
      end)

    return_summary(length(files), successes, failures)
  end

  defp seed_file(path) do
    with {:ok, xml} <- File.read(path),
         {:ok, definitions} <- EvilEngine.BPMN.parse_and_validate(xml),
         :ok <- run_linter_gate(definitions, path) do
      count = deploy_processes(definitions, xml, path)
      {:ok, count}
    else
      {:error, reason} ->
        Logger.warning("[SeedingRunner] Skipping #{Path.basename(path)}: #{inspect(reason)}")
        :error
    end
  end

  defp run_linter_gate(definitions, path) do
    gate_config = Application.get_env(:core_bpmn, :linter_gate, [])
    skip_seeding = Keyword.get(gate_config, :skip_seeding, false)

    if skip_seeding do
      :ok
    else
      case LinterGate.check(definitions) do
        {:ok, :passed} ->
          :ok

        {:error, failures} ->
          {:error, {:linter_gate_failed, Path.basename(path), failures}}
      end
    end
  end

  defp deploy_processes(definitions, xml, path) do
    persist_function = Application.get_env(:core_bpmn, :seeding_persist_fn)

    Enum.count(definitions.processes, fn process ->
      version_id = generate_uuid()
      maybe_persist(persist_function, process, xml, version_id, path)
      ModelCache.put_new(version_id, definitions)
      Logger.info("[SeedingRunner] Cached process '#{process.id}' from #{Path.basename(path)}")
      true
    end)
  end

  defp maybe_persist(nil, _process, _xml, _version_id, _path), do: :ok

  defp maybe_persist(persist_function, process, xml, version_id, path) do
    case persist_function.(process, xml, version_id) do
      {:ok, _} ->
        Logger.info(
          "[SeedingRunner] Deployed '#{process.id}' v#{process.version} from #{Path.basename(path)}"
        )

      {:error, reason} ->
        Logger.warning("[SeedingRunner] Failed to persist '#{process.id}': #{inspect(reason)}")
    end
  end

  defp generate_uuid do
    <<u0::48, _::4, u1::12, _::2, u2::62>> = :crypto.strong_rand_bytes(16)

    <<u0::48, 4::4, u1::12, 2::2, u2::62>>
    |> Base.encode16(case: :lower)
    |> format_uuid_hex()
  end

  defp format_uuid_hex(hex) do
    <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> = hex
    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end

  defp return_summary(file_count, successes, failures) do
    Logger.info(
      "[SeedingRunner] Seeded #{successes} processes from #{file_count} files, #{failures} failures"
    )

    :ok
  end
end
