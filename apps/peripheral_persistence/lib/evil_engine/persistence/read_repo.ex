defmodule EvilEngine.Persistence.ReadRepo do
  @moduledoc """
  Read-only `AshPostgres.Repo` for GraphQL queries and REST reads.

  Connects to the same PostgreSQL database as the write `Repo`, but
  uses a separate connection pool (`TDE_DB_READ_POOL_SIZE`, default 50).
  This isolates read traffic from latency-critical execution writes.

  Pool tuning parameters are shared with the write Repo via the
  `:db_pool_tuning` config.

  ## Read-only enforcement

  Writes are prevented at two layers:

  1. **Ash routing** (primary): `RepoRouter.repo/2` routes all `:mutate`
     actions to the write `Repo`; only `:read` actions reach `ReadRepo`.
  2. **Ecto guard** (defense-in-depth): `insert/2` and `insert!/2` raise
     at runtime if called directly, catching accidental bypass of the
     Ash layer. Ecto's compile-time `read_only: true` cannot be used
     because AshPostgres assumes write functions are defined.
  """

  use AshPostgres.Repo, otp_app: :peripheral_persistence

  defoverridable insert: 1, insert: 2, insert!: 1, insert!: 2

  @dialyzer {:nowarn_function, all_tenants: 0}
  @dialyzer {:nowarn_function, insert: 1}
  @dialyzer {:nowarn_function, insert: 2}
  @dialyzer {:nowarn_function, insert!: 1}
  @dialyzer {:nowarn_function, insert!: 2}

  @impl Ecto.Repo
  def insert(_struct_or_changeset, _opts \\ []) do
    raise RuntimeError, "ReadRepo is read-only — writes must go through the write Repo"
  end

  @impl Ecto.Repo
  def insert!(_struct_or_changeset, _opts \\ []) do
    raise RuntimeError, "ReadRepo is read-only — writes must go through the write Repo"
  end

  @doc false
  @impl true
  def installed_extensions do
    ["uuid-ossp", "ash-functions"]
  end

  @doc false
  @impl true
  def min_pg_version do
    %Version{major: 16, minor: 0, patch: 0, pre: [], build: nil}
  end

  @doc false
  @impl true
  def init(_context, config) do
    tuning = Application.get_env(:peripheral_persistence, :db_pool_tuning, [])

    config =
      config
      |> put_if_missing(:checkout_retries, tuning[:checkout_retries])
      |> put_if_missing(:queue_target, tuning[:queue_target])
      |> put_if_missing(:queue_interval, tuning[:queue_interval])
      |> put_if_missing(:timeout, tuning[:timeout])

    {:ok, config}
  end

  defp put_if_missing(config, _key, nil), do: config
  defp put_if_missing(config, key, value), do: Keyword.put_new(config, key, value)
end
