defmodule BfwEngine.Persistence.Repo do
  @moduledoc """
  Primary (write) `AshPostgres.Repo` for the engine.

  Postgres 16+ is required — we rely on `COMPRESSION lz4` and
  declarative partitioning.

  Pool tuning parameters (CoDel `queue_target`/`queue_interval`,
  `checkout_retries`, `timeout`) are applied from the shared
  `:db_pool_tuning` config at init time, so they take effect in
  every environment — not just prod.
  """

  use AshPostgres.Repo, otp_app: :peripheral_persistence

  @dialyzer {:nowarn_function, all_tenants: 0}

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
