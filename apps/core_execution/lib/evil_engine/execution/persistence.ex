defmodule EvilEngine.Execution.Persistence do
  @moduledoc """
  Behaviour defining persistence operations the PI runtime needs.

  Core execution defines this contract; the actual implementation
  lives in `peripheral_persistence` and is wired via application
  config (`:core_execution, :persistence_adapter`). This preserves
  the dependency direction (Core never imports Peripheral).

  In tests, a no-op or in-memory adapter can be used.

  ## Two-layer retry semantics

  Adapter calls are protected by two complementary retry layers:

  - **Layer 1** — `DBConnection.checkout_retries` (default 3) handles
    mid-query disconnects transparently at the pool level.
  - **Layer 2** — `PersistenceRetry.with_retry/3` wraps each adapter
    call with bounded exponential backoff (default 5 attempts, ~3.1s
    total). This handles pool exhaustion, DB unreachable, and query
    timeouts.

  The adapter itself should NOT retry internally — retry is the caller's
  responsibility via Layer 2.
  """

  @type process_instance_attributes :: map()
  @type flow_node_instance_attributes :: map()

  @type retry_pi_data :: %{
          id: String.t(),
          state: String.t(),
          finished_at: DateTime.t() | nil,
          process_version_id: String.t(),
          parent_process_instance_id: String.t() | nil,
          started_by: map(),
          started_at: DateTime.t(),
          started_with_context: map() | nil,
          business_key: String.t() | nil,
          triggerer_flow_node_instance_id: String.t() | nil,
          error_info: map() | nil
        }

  @type retry_fni_data :: %{
          id: String.t(),
          flow_node_id: String.t(),
          flow_node_type: String.t(),
          event_type: String.t() | nil,
          state: String.t(),
          started_at: DateTime.t(),
          input_token: map() | nil,
          output_token: map() | nil,
          type_properties: map(),
          previous_flow_node_instance_ids: [String.t()],
          lane_name: String.t() | nil,
          error_info: map() | nil
        }

  @callback create_process_instance(process_instance_attributes()) ::
              {:ok, map()} | {:error, term()}
  @callback update_process_instance(String.t(), map()) :: :ok | {:error, term()}
  @callback create_flow_node_instance(flow_node_instance_attributes()) ::
              {:ok, map()} | {:error, term()}
  @callback update_flow_node_instance(String.t(), atom(), map()) :: :ok | {:error, term()}
  @doc """
  Returns one page of root-level running process instances (those without a
  parent), used by `ResumeRunner` for paginated resume at boot. Child PIs
  spawned by Call Activities are resumed by their parent's handler, not by
  `ResumeRunner` directly.

  ## Options

  - `:limit` (positive integer, required) — page size
  - `:after` (`term() | nil`) — opaque cursor returned by the previous call;
    `nil` (or omitted) means "first page"

  ## Result

  Returns `{:ok, %{records: [pi_map], next_cursor: term() | nil}}`. The
  cursor is opaque — the caller passes it back as `:after` on the next
  call. `next_cursor: nil` signals end-of-stream (no more pages).

  Adapters are free to choose any stable cursor representation. The Ash
  adapter uses the last record's `id` (UUID v7 monotonic) plus a stable
  sort on `id` to provide natural keyset semantics without requiring
  Ash's pagination machinery.
  """
  @callback list_running_process_instances(opts :: keyword()) ::
              {:ok, %{records: [map()], next_cursor: term() | nil}} | {:error, term()}

  @doc """
  Read FNIs needed for resume of a PI.

  Returns:
  - All `:active` and `:waiting` FNIs — the resume path's `reactivate_fnis/1`
    re-dispatches active handlers and re-attaches waiting ones (async parks,
    Call Activity children, User Tasks).
  - All `:finished` End-Event FNIs — needed by `build_final_tokens/1` for multi-End
    multi-End-Event aggregation across restarts.

  The End-Event clause is forward-compat with Phase 2 items 13-14 (Message
  and Signal Boundary Events with non-interrupting variants), Phase 3
  Parallel/Inclusive Gateways, and Phase 4 Compensation. With the current
  Phase-1/2-up-to-item-9 feature set, no PI can produce multiple finished
  End-Event FNIs in a single execution, so this clause loads zero extra
  rows today; it costs nothing to ship now and prevents a silent multi-End bug
  when the fan-out features arrive.

  Other terminal FNIs (`:fatal`, `:aborted`, `:interrupted`, plus
  `:finished` non-End-Events) are not loaded — the live PI never reads
  their history.
  """
  @callback list_flow_node_instances(String.t()) :: {:ok, [map()]} | {:error, term()}

  @doc """
  Atomically UPSERT the Data Object snapshot and INSERT an audit row.

  Returns `{:ok, %{write_id: id, created_at: datetime}}` on success.
  """
  @callback write_data_object(params :: map()) :: {:ok, map()} | {:error, term()}

  @doc """
  Atomically finish an FNI and persist all Data Object write intents
  in a single transaction. The FNI is updated to `:finished` state
  and all DO snapshot UPSERTs + audit INSERTs are executed together.

  When `write_intents` is `[]`, only the FNI update is performed.

  Returns `{:ok, %{writes: [%{write_id, created_at}, ...]}}` on success.
  """
  @callback finish_fni_with_data_objects(
              fni_id :: String.t(),
              fni_changes :: map(),
              write_intents :: [EvilEngine.Execution.DataObjectWriteIntent.t()]
            ) :: {:ok, %{writes: [map()]}} | {:error, term()}

  @doc """
  List current Data Object snapshots for a process instance (used for resume rehydration).
  """
  @callback list_data_objects(process_instance_id :: String.t()) ::
              {:ok, [map()]} | {:error, term()}

  @doc """
  Boot-time sweep: transition all FNIs in non-terminal state (`active`/`waiting`)
  whose PI is already terminal (`finished`/`fatal`/`aborted`) to `aborted`.

  Returns `{:ok, count}` with the number of rows affected.
  """
  @callback cleanup_orphaned_flow_node_instances() ::
              {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Boot-time sweep: transition orphaned child PIs (running, with a
  `parent_process_instance_id` pointing to a terminal PI) to `aborted`.
  Handles nested orphans iteratively (grandchild, great-grandchild, etc.).

  Returns `{:ok, count}` with the total number of PIs affected across
  all passes.
  """
  @callback cleanup_orphaned_process_instances() ::
              {:ok, non_neg_integer()} | {:error, term()}

  # ---------------------------------------------------------------------------
  # Retry/restart callbacks
  # ---------------------------------------------------------------------------

  @doc "Read a PI by ID for retry validation. Returns full row data including started_by."
  @callback get_process_instance_for_retry(process_instance_id :: String.t()) ::
              {:ok, retry_pi_data()} | {:error, :not_found}

  @doc "Read ALL FNIs for a PI (all states). Used for retry preparation."
  @callback list_all_flow_node_instances(process_instance_id :: String.t()) ::
              {:ok, [retry_fni_data()]}

  @doc """
  Atomically prepare a PI for retry:
  1. If `delete_fni_ids` provided: cascade-delete child PIs of any Call Activity
     FNIs in the set, roll back Data Object writes from deleted FNIs, then
     delete the FNI rows.
  2. Reset specified FNI states (fatal/aborted -> active)
  3. If `version_id` provided: update PI `process_version_id`
  4. Reset PI state to "running", clear `finished_at` and `error_info`

  The `delete_fni_ids` list is pre-computed by the caller via forward
  reachability traversal. It contains `{fni_id, flow_node_type,
  type_properties}` tuples so the adapter can identify Call Activity FNIs
  and their child PI IDs without additional queries.

  Returns `{:ok, [retry_fni_data]}` with the FNIs that will be reactivated
  (active + waiting after reset), or `{:error, reason}`.
  """
  @callback execute_retry_reset(
              process_instance_id :: String.t(),
              opts :: %{
                optional(:version_id) => String.t(),
                optional(:delete_fni_ids) => [{String.t(), String.t(), map()}],
                optional(:reset_fni_ids) => [{String.t(), String.t()}]
              }
            ) :: {:ok, [retry_fni_data()]} | {:error, term()}

  @doc """
  List direct child process instances of a parent PI.

  Returns `[%{id, state, triggerer_flow_node_instance_id}]` for every
  non-deleted PI whose `parent_process_instance_id` equals the given ID.
  Used by `reset_descendants` to discover children authoritatively
  rather than relying on FNI `type_properties`.
  """
  @callback list_child_process_instances(parent_process_instance_id :: String.t()) ::
              {:ok, [%{id: String.t(), state: String.t(), triggerer_flow_node_instance_id: String.t() | nil}]}
              | {:error, term()}

  @doc """
  Patch a single FNI's type_properties in the database.

  Merges `patch` into the existing `type_properties` column. Used to
  reconcile `child_process_instance_id` on parent FNIs after children
  are discovered by `parent_process_instance_id` query.
  """
  @callback patch_fni_type_properties(
              flow_node_instance_id :: String.t(),
              patch :: map()
            ) :: :ok | {:error, term()}

  @doc "Revert a failed retry: set PI back to terminal state."
  @callback revert_retry(
              process_instance_id :: String.t(),
              original_state :: String.t(),
              original_finished_at :: DateTime.t()
            ) :: :ok | {:error, term()}

  # ---------------------------------------------------------------------------
  # Gateway pending arrival callbacks
  # ---------------------------------------------------------------------------

  @doc "Persist a branch arrival at a parallel/inclusive gateway join."
  @callback create_gateway_pending_arrival(params :: map()) ::
              {:ok, map()} | {:error, term()}

  @doc "List all pending arrivals for a process instance (used for resume)."
  @callback list_gateway_pending_arrivals(process_instance_id :: String.t()) ::
              {:ok, [map()]} | {:error, term()}

  @doc "Delete all pending arrival rows for a specific gateway FNI (used on join fire and cleanup)."
  @callback delete_gateway_pending_arrivals_for_gateway(
              gateway_flow_node_instance_id :: String.t()
            ) :: :ok | {:error, term()}

  @doc "Returns the configured persistence adapter module."
  @spec adapter() :: module()
  def adapter do
    Application.get_env(:core_execution, :persistence_adapter, __MODULE__.NoOp)
  end
end

defmodule EvilEngine.Execution.Persistence.NoOp do
  @moduledoc "No-op adapter for tests and standalone usage without a database."

  @behaviour EvilEngine.Execution.Persistence

  @impl true
  def create_process_instance(attributes), do: {:ok, attributes}

  @impl true
  def update_process_instance(_id, _changes), do: :ok

  @impl true
  def create_flow_node_instance(attributes), do: {:ok, attributes}

  @impl true
  def update_flow_node_instance(_id, _action, _changes), do: :ok

  @impl true
  def list_running_process_instances(_opts), do: {:ok, %{records: [], next_cursor: nil}}

  @impl true
  def list_flow_node_instances(_process_instance_id), do: {:ok, []}

  @impl true
  def finish_fni_with_data_objects(_fni_id, _fni_changes, intents) do
    now = DateTime.utc_now()
    writes = Enum.map(intents, fn _intent -> %{write_id: "noop", created_at: now} end)
    {:ok, %{writes: writes}}
  end

  @impl true
  def write_data_object(_params), do: {:ok, %{write_id: "noop", created_at: DateTime.utc_now()}}

  @impl true
  def list_data_objects(_process_instance_id), do: {:ok, []}

  @impl true
  def cleanup_orphaned_flow_node_instances, do: {:ok, 0}

  @impl true
  def cleanup_orphaned_process_instances, do: {:ok, 0}

  @impl true
  def get_process_instance_for_retry(_process_instance_id), do: {:error, :not_found}

  @impl true
  def list_all_flow_node_instances(_process_instance_id), do: {:ok, []}

  @impl true
  def list_child_process_instances(_parent_process_instance_id), do: {:ok, []}

  @impl true
  def patch_fni_type_properties(_flow_node_instance_id, _patch), do: :ok

  @impl true
  def execute_retry_reset(_process_instance_id, _opts), do: {:ok, []}

  @impl true
  def revert_retry(_process_instance_id, _original_state, _original_finished_at), do: :ok

  @impl true
  def create_gateway_pending_arrival(params), do: {:ok, params}

  @impl true
  def list_gateway_pending_arrivals(_process_instance_id), do: {:ok, []}

  @impl true
  def delete_gateway_pending_arrivals_for_gateway(_gateway_flow_node_instance_id), do: :ok
end
