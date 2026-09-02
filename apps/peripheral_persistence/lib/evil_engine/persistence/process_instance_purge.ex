defmodule EvilEngine.Persistence.ProcessInstancePurge do
  @moduledoc """
  Hard-deletes terminal process-instance trees for retention.

  Selection is root-only (`parent_process_instance_id IS NULL`). A root is
  skipped when any descendant is `running` or `suspended`. Eligible trees
  are deleted set-based in one transaction per root, including every
  descendant even if a child is younger than the cutoff.

  Used by `mix evil.retention.purge` and by retry cascade in
  `EvilEngine.Persistence.ExecutionAdapter`.
  """

  alias Ecto.Adapters.SQL, as: EctoSQL
  alias EvilEngine.Persistence.Repo

  @state_config_keys [
    {"finished", :finished_days},
    {"error", :error_days},
    {"fatal", :fatal_days},
    {"aborted", :aborted_days},
    {"escalated", :escalated_days},
    {"compensated", :compensated_days},
    {"cancelled", :cancelled_days}
  ]

  @non_terminal_states ["running", "suspended"]

  @doc """
  Select and purge eligible root trees.

  Options:

    * `:retention_config` — keyword list (defaults to Application env)
    * `:batch_size` — max roots per invocation (defaults to config, then 500)
    * `:now` — cutoff clock (defaults to `DateTime.utc_now/0`)
    * `:dry_run` — when `true`, count without deleting
  """
  @spec purge_eligible_trees(keyword()) ::
          {:ok,
           %{
             purged_root_count: non_neg_integer(),
             skipped_root_count: non_neg_integer(),
             dry_run: boolean()
           }}
          | {:error, term()}
  def purge_eligible_trees(opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    retention_config =
      Keyword.get(
        opts,
        :retention_config,
        Application.get_env(:peripheral_persistence, :retention, [])
      )

    configured_batch_size =
      parse_positive_integer(Keyword.get(retention_config, :batch_size))

    batch_size = Keyword.get(opts, :batch_size, configured_batch_size || 500)

    root_ids = eligible_root_ids(retention_config, batch_size, now)

    Enum.reduce_while(root_ids, {0, 0}, fn root_id, {purged_root_count, skipped_root_count} ->
      if tree_has_non_terminal_descendant?(root_id) do
        {:cont, {purged_root_count, skipped_root_count + 1}}
      else
        purge_or_count_root(root_id, dry_run, purged_root_count, skipped_root_count)
      end
    end)
    |> case do
      {:error, reason} ->
        {:error, reason}

      {purged_root_count, skipped_root_count} ->
        {:ok,
         %{
           purged_root_count: purged_root_count,
           skipped_root_count: skipped_root_count,
           dry_run: dry_run
         }}
    end
  end

  @doc """
  True when at least one per-state days knob parses as a positive integer.

  Used by `mix evil.retention.purge` to print the no-op message without
  running a select. Invalid values (`0`, `""`, `"abc"`) do not count.
  """
  @spec any_days_policy?(keyword()) :: boolean()
  def any_days_policy?(retention_config) do
    Enum.any?(@state_config_keys, fn {_state, config_key} ->
      parse_positive_integer(Keyword.get(retention_config, config_key)) != nil
    end)
  end

  @doc """
  Root process instance IDs whose `finished_at` is older than the
  configured per-state cutoff. Bypasses the Ash soft-delete filter.
  """
  @spec eligible_root_ids(keyword(), pos_integer(), DateTime.t()) :: [String.t()]
  def eligible_root_ids(retention_config, batch_size, now) do
    clauses = cutoff_clauses(retention_config, now)

    if clauses == [] do
      []
    else
      {where_sql, parameters} = build_eligibility_where(clauses)
      limit_index = length(parameters) + 1

      sql = """
      SELECT id::text
      FROM process_instances
      WHERE parent_process_instance_id IS NULL
        AND (#{where_sql})
      ORDER BY finished_at ASC NULLS LAST
      LIMIT $#{limit_index}
      """

      %{rows: rows} = EctoSQL.query!(Repo, sql, parameters ++ [batch_size])
      Enum.map(rows, fn [process_instance_id] -> process_instance_id end)
    end
  end

  @doc """
  True when any descendant (not the root) is `running` or `suspended`.
  """
  @spec tree_has_non_terminal_descendant?(String.t()) :: boolean()
  def tree_has_non_terminal_descendant?(root_process_instance_id) do
    sql = """
    WITH RECURSIVE tree AS (
      SELECT id FROM process_instances WHERE id = $1::uuid
      UNION
      SELECT child.id
      FROM process_instances AS child
      INNER JOIN tree ON child.parent_process_instance_id = tree.id
    )
    SELECT EXISTS (
      SELECT 1
      FROM tree
      INNER JOIN process_instances AS process_instance ON process_instance.id = tree.id
      WHERE process_instance.id <> $1::uuid
        AND process_instance.state = ANY($2::text[])
    )
    """

    case EctoSQL.query(Repo, sql, [dump_uuid!(root_process_instance_id), @non_terminal_states]) do
      {:ok, %{rows: [[true]]}} -> true
      {:ok, %{rows: [[false]]}} -> false
      {:ok, %{rows: []}} -> false
      {:error, _reason} -> true
    end
  end

  @doc """
  Hard-delete one process instance and every descendant linked by
  `parent_process_instance_id`, plus related execution rows.
  """
  @spec hard_delete_process_instance_tree(String.t()) :: :ok | {:error, term()}
  def hard_delete_process_instance_tree(process_instance_id) do
    case Repo.transaction(fn ->
           process_instance_ids = descendant_ids_including_self!(process_instance_id)
           delete_rows_for_process_instance_ids!(process_instance_ids)
         end) do
      {:ok, :ok} -> :ok
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp purge_or_count_root(_root_id, true, purged_root_count, skipped_root_count) do
    {:cont, {purged_root_count + 1, skipped_root_count}}
  end

  defp purge_or_count_root(root_id, false, purged_root_count, skipped_root_count) do
    case hard_delete_process_instance_tree(root_id) do
      :ok ->
        {:cont, {purged_root_count + 1, skipped_root_count}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp cutoff_clauses(retention_config, now) do
    Enum.flat_map(@state_config_keys, fn {state, config_key} ->
      case parse_positive_integer(Keyword.get(retention_config, config_key)) do
        nil ->
          []

        days ->
          [{state, DateTime.add(now, -days, :day)}]
      end
    end)
  end

  defp build_eligibility_where(clauses) do
    {fragments, parameters, _next_index} =
      Enum.reduce(clauses, {[], [], 1}, fn {state, cutoff}, {fragments, parameters, index} ->
        fragment =
          "(state = $#{index} AND finished_at IS NOT NULL AND finished_at < $#{index + 1})"

        {fragments ++ [fragment], parameters ++ [state, cutoff], index + 2}
      end)

    {Enum.join(fragments, " OR "), parameters}
  end

  defp descendant_ids_including_self!(process_instance_id) do
    sql = """
    WITH RECURSIVE tree AS (
      SELECT id FROM process_instances WHERE id = $1::uuid
      UNION
      SELECT child.id
      FROM process_instances AS child
      INNER JOIN tree ON child.parent_process_instance_id = tree.id
    )
    SELECT id::text FROM tree
    """

    case EctoSQL.query(Repo, sql, [dump_uuid!(process_instance_id)]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [id] -> id end)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp delete_rows_for_process_instance_ids!([]), do: :ok

  defp delete_rows_for_process_instance_ids!(process_instance_ids) do
    delete_statements = [
      "DELETE FROM process_instance_events WHERE process_instance_id = ANY($1::uuid[])",
      "DELETE FROM gateway_pending_arrivals WHERE process_instance_id = ANY($1::uuid[])",
      "DELETE FROM data_object_writes WHERE process_instance_id = ANY($1::uuid[])",
      "DELETE FROM data_objects WHERE process_instance_id = ANY($1::uuid[])",
      "DELETE FROM flow_node_instances WHERE process_instance_id = ANY($1::uuid[])",
      "DELETE FROM process_instances WHERE id = ANY($1::uuid[])"
    ]

    uuid_binaries = Enum.map(process_instance_ids, &dump_uuid!/1)

    Enum.each(delete_statements, fn delete_sql ->
      case EctoSQL.query(Repo, delete_sql, [uuid_binaries]) do
        {:ok, _result} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end)

    :ok
  end

  defp parse_positive_integer(nil), do: nil
  defp parse_positive_integer(""), do: nil

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_integer(value), do: nil

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil

  defp dump_uuid!(uuid_string) do
    {:ok, binary} = Ecto.UUID.dump(uuid_string)
    binary
  end
end
