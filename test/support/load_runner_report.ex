defmodule EvilEngine.Test.LoadRunnerReport do
  @moduledoc """
  After-run hook for `test/load_runner.exs`.

  Writes the pretty JSON report even when ExUnit failed, then applies halt
  codes: 1 for test failures, 2 for a missing/unreadable baseline or a KPI
  regression when `EVIL_LOAD_BASELINE_PATH` is set.
  """

  alias EvilEngine.Test.BenchmarkReporter

  @failure_exit_status 1
  @regression_exit_status 2

  @doc """
  Write `test/load/reports/<utc_compact>.json`, print the path, then halt
  according to ExUnit failures and `EVIL_LOAD_BASELINE_PATH`.
  """
  def finish!(failures, reports_directory \\ default_reports_directory())
      when is_integer(failures) and is_binary(reports_directory) do
    report_path = write_report!(reports_directory)
    apply_exit_status(failures, report_path)
  end

  @doc """
  Snapshot the reporter into a pretty JSON file under `reports_directory`.
  """
  def write_report!(reports_directory) when is_binary(reports_directory) do
    ensure_reporter_started()

    timestamp =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601(:basic)
      |> String.replace(" ", "")

    report_path = Path.join(reports_directory, "#{timestamp}.json")
    BenchmarkReporter.write!(report_path)
    IO.puts("Wrote benchmark report: #{report_path}")
    report_path
  end

  @doc """
  Halt 1 when `failures > 0`. Halt 2 when a baseline path is set and the
  file is missing, unreadable, invalid, or KPIs regress. Otherwise `:ok`.
  """
  def apply_exit_status(failures, report_path)
      when is_integer(failures) and is_binary(report_path) do
    baseline_path = System.get_env("EVIL_LOAD_BASELINE_PATH")

    cond do
      failures > 0 ->
        IO.puts("\n\e[31m✗ #{failures} load test failure(s). Aborting.\e[0m")
        System.halt(@failure_exit_status)

      is_binary(baseline_path) and baseline_path != "" ->
        compare_baseline_file(baseline_path, report_path)

      true ->
        :ok
    end
  end

  defp ensure_reporter_started do
    # Unit tests must not stop the named reporter. Restart is only for crash
    # recovery and yields empty workloads.
    case Process.whereis(BenchmarkReporter) do
      nil ->
        {:ok, _pid} = BenchmarkReporter.start_link()
        :ok

      _pid ->
        :ok
    end
  end

  defp compare_baseline_file(baseline_path, report_path) do
    baseline = read_baseline_map!(baseline_path)
    current = report_path |> File.read!() |> Jason.decode!()
    report_compare_result(BenchmarkReporter.compare_baseline(baseline, current))
  end

  defp read_baseline_map!(baseline_path) do
    baseline_path
    |> File.read()
    |> decode_baseline_contents!(baseline_path)
  end

  defp decode_baseline_contents!({:error, reason}, baseline_path) do
    IO.puts(
      "\e[31mKPI baseline file is missing or unreadable: #{baseline_path} (#{inspect(reason)})\e[0m"
    )

    System.halt(@regression_exit_status)
  end

  defp decode_baseline_contents!({:ok, contents}, baseline_path) do
    case Jason.decode(contents) do
      {:ok, baseline} when is_map(baseline) ->
        baseline

      {:ok, _other} ->
        IO.puts("\e[31mKPI baseline file is not a JSON object: #{baseline_path}\e[0m")
        System.halt(@regression_exit_status)

      {:error, decode_error} ->
        IO.puts(
          "\e[31mKPI baseline file is not valid JSON: #{baseline_path} (#{Exception.message(decode_error)})\e[0m"
        )

        System.halt(@regression_exit_status)
    end
  end

  defp report_compare_result(:ok), do: :ok

  defp report_compare_result({:error, regressions}) do
    Enum.each(regressions, &IO.puts("\e[31mKPI regression: #{&1}\e[0m"))
    System.halt(@regression_exit_status)
  end

  defp default_reports_directory do
    Path.expand("../load/reports", __DIR__)
  end
end
