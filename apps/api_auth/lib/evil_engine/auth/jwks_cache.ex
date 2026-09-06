defmodule EvilEngine.Auth.JwksCache do
  @moduledoc """
  Periodically fetches and caches the JWKS (JSON Web Key Set) from the
  configured `TDE_JWT_JWKS_URL`.

  Refresh interval: `TDE_JWKS_REFRESH_SECONDS` (default 3600).
  On failure the stale keyset is retained until the next successful
  fetch; a warning is logged on every failed attempt.
  """

  use GenServer

  require Logger

  @default_refresh_ms 3_600_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the cached JOSE.JWK set, or `nil` if no JWKS is configured."
  @spec get_keys() :: JOSE.JWK.t() | nil
  def get_keys do
    GenServer.call(__MODULE__, :get_keys)
  end

  @doc "Force an immediate refresh (useful in tests)."
  @spec refresh() :: :ok
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  # --- Server callbacks ---------------------------------------------------

  @impl true
  def init(opts) do
    url = Keyword.get(opts, :jwks_url)
    refresh_ms = Keyword.get(opts, :refresh_ms, @default_refresh_ms)

    state = %{
      url: url,
      refresh_ms: refresh_ms,
      keys: nil,
      last_fetched_at: nil,
      consecutive_failures: 0
    }

    if url do
      send(self(), :fetch)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:get_keys, _from, state) do
    {:reply, state.keys, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    new_state = do_fetch(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:fetch, state) do
    new_state = do_fetch(state)
    schedule_refresh(new_state.refresh_ms)
    {:noreply, new_state}
  end

  defp do_fetch(%{url: nil} = state), do: state

  defp do_fetch(%{url: url} = state) do
    case fetch_jwks(url) do
      {:ok, jwk} ->
        Logger.info("JWKS refreshed from #{url}")

        %{
          state
          | keys: jwk,
            last_fetched_at: DateTime.utc_now(),
            consecutive_failures: 0
        }

      {:error, reason} ->
        Logger.warning(
          "JWKS fetch failed (#{state.consecutive_failures + 1}): #{inspect(reason)}"
        )

        %{state | consecutive_failures: state.consecutive_failures + 1}
    end
  end

  defp fetch_jwks(url) do
    case :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, 10_000}], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        jwk =
          body
          |> IO.iodata_to_binary()
          |> Jason.decode!()
          |> JOSE.JWK.from_map()

        {:ok, jwk}

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  defp schedule_refresh(ms) do
    Process.send_after(self(), :fetch, ms)
  end
end
