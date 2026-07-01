defmodule EvilEngine.Persistence.Partitions do
  @moduledoc """
  Partition management for time-range partitioned audit tables.

  Creates child partitions ahead of time based on the configured
  `EVIL_PARTITION_INTERVAL` (monthly, quarterly, half_yearly, yearly).
  When interval is `:off`, all operations are no-ops.

  The declarative `@partitioned_tables` list is the single source of
  truth for which tables are partitioned. Adding a new partitioned
  table is a one-line change here.
  """

  require Logger

  alias EvilEngine.Persistence.Repo

  @partitioned_tables [
    {"process_instance_events", :occurred_at},
    {"data_object_writes", :created_at},
    {"messages", :published_at},
    {"pending_messages", :published_at},
    {"signals", :published_at},
    {"pending_signals", :published_at}
  ]

  @doc """
  Pre-create partitions for all partitioned tables, from the current
  period through `ahead_months` into the future.

  Returns `{:ok, created_count}`.
  """
  @spec ensure_partitions() :: {:ok, non_neg_integer()}
  def ensure_partitions do
    interval = partition_interval()

    if interval == :off do
      Logger.info("Partitioning disabled (EVIL_PARTITION_INTERVAL=off)")
      {:ok, 0}
    else
      ahead_months = partition_ahead_months()
      periods = generate_periods(interval, ahead_months)
      created = create_partitions(periods)
      Logger.info("Partition check complete: #{created} partition(s) ensured")
      {:ok, created}
    end
  end

  @doc "Returns the list of partitioned table names."
  @spec partitioned_tables() :: [{String.t(), atom()}]
  def partitioned_tables, do: @partitioned_tables

  defp partition_interval do
    Application.get_env(:peripheral_persistence, :partition_interval, :quarterly)
  end

  defp partition_ahead_months do
    retention = Application.get_env(:peripheral_persistence, :retention, [])
    Keyword.get(retention, :partition_ahead_months, 3)
  end

  defp generate_periods(interval, ahead_months) do
    today = Date.utc_today()
    current_period_start = period_start(today, interval)

    ahead_periods =
      case interval do
        :monthly -> ahead_months
        :quarterly -> max(div(ahead_months, 3), 1) + 1
        :half_yearly -> max(div(ahead_months, 6), 1) + 1
        :yearly -> max(div(ahead_months, 12), 1) + 1
      end

    for i <- 0..ahead_periods do
      start_date = advance_period(current_period_start, interval, i)
      end_date = advance_period(current_period_start, interval, i + 1)
      suffix = partition_suffix(start_date, interval)
      {start_date, end_date, suffix}
    end
  end

  defp period_start(date, :monthly) do
    Date.new!(date.year, date.month, 1)
  end

  defp period_start(date, :quarterly) do
    quarter_month = div(date.month - 1, 3) * 3 + 1
    Date.new!(date.year, quarter_month, 1)
  end

  defp period_start(date, :half_yearly) do
    half_month = if date.month <= 6, do: 1, else: 7
    Date.new!(date.year, half_month, 1)
  end

  defp period_start(date, :yearly) do
    Date.new!(date.year, 1, 1)
  end

  defp advance_period(date, :monthly, n) do
    total_months = date.year * 12 + (date.month - 1) + n
    year = div(total_months, 12)
    month = rem(total_months, 12) + 1
    Date.new!(year, month, 1)
  end

  defp advance_period(date, :quarterly, n) do
    advance_period(date, :monthly, n * 3)
  end

  defp advance_period(date, :half_yearly, n) do
    advance_period(date, :monthly, n * 6)
  end

  defp advance_period(date, :yearly, n) do
    Date.new!(date.year + n, 1, 1)
  end

  defp partition_suffix(date, :monthly) do
    year = date.year
    month = date.month |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{year}_#{month}"
  end

  defp partition_suffix(date, :quarterly) do
    quarter = div(date.month - 1, 3) + 1
    "#{date.year}_q#{quarter}"
  end

  defp partition_suffix(date, :half_yearly) do
    half = if date.month <= 6, do: 1, else: 2
    "#{date.year}_h#{half}"
  end

  defp partition_suffix(date, :yearly) do
    "#{date.year}"
  end

  defp create_partitions(periods) do
    Enum.reduce(@partitioned_tables, 0, fn {table, _ts_col}, acc ->
      count =
        Enum.count(periods, fn {start_date, end_date, suffix} ->
          partition_name = "#{table}_#{suffix}"
          create_partition(table, partition_name, start_date, end_date)
        end)

      acc + count
    end)
  end

  defp create_partition(parent_table, partition_name, %Date{} = start_date, %Date{} = end_date) do
    # Postgres DOES NOT support parameter binding inside the
    # `CREATE TABLE ... PARTITION OF ... FOR VALUES FROM (...) TO (...)`
    # clause: the prepared-statement parser reports zero parameter slots
    # for partition bound expressions and rejects `$1`/`$2` placeholders
    # with `parameters must be of length 0 for query`. Identifiers
    # (parent_table, partition_name) likewise cannot be parameterized in
    # DDL. Inline interpolation is therefore unavoidable here.
    #
    # Safety is achieved by construction rather than by parameter binding:
    #
    # - `parent_table` is taken verbatim from the `@partitioned_tables`
    #   module-attribute constant. No user input reaches it.
    # - `partition_name` is `parent_table` joined with a deterministic
    #   suffix produced by `partition_suffix/2` — also no user input.
    # - `start_date` / `end_date` are guarded as `%Date{}` structs by the
    #   function head; non-Date callers fail fast with a FunctionClauseError
    #   instead of producing arbitrary text. `Date.to_iso8601/1` always
    #   emits the strict `YYYY-MM-DD` format with no quote-escaping
    #   surprises.
    sql = """
    CREATE TABLE IF NOT EXISTS #{partition_name}
    PARTITION OF #{parent_table}
    FOR VALUES FROM ('#{Date.to_iso8601(start_date)}') TO ('#{Date.to_iso8601(end_date)}')
    """

    # IF NOT EXISTS handles the common case; the duplicate_table guard
    # is a safety net for concurrent callers racing on the same partition.
    case Repo.query(sql) do
      {:ok, _} ->
        true

      {:error, %{postgres: %{code: :duplicate_table}}} ->
        false

      {:error, reason} ->
        Logger.warning("Failed to create partition #{partition_name}: #{inspect(reason)}")
        false
    end
  end
end
