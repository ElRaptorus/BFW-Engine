defmodule EvilEngine.Auth.ProviderRegistry do
  @moduledoc """
  Holds a reference to the active auth provider module.

  Starts with `JwtAuthProvider` (the built-in default). A plugin may
  replace it once via `register_provider/1`. The second call from a
  different plugin returns `{:error, :already_registered}` (first-writer
  wins, consistent with all other unique plugin capabilities).
  """

  use GenServer

  alias EvilEngine.Types.Identity

  @default_provider EvilEngine.Auth.JwtAuthProvider

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns the currently active auth provider module."
  @spec active_provider() :: module()
  def active_provider,
    do: GenServer.call(__MODULE__, :active_provider)

  @doc """
  Register a plugin auth provider (first-writer wins).

  Replaces the built-in default on the first call. If a plugin provider
  is already registered, returns `{:error, :already_registered}`.
  """
  @spec register_provider(module()) :: :ok | {:error, :already_registered}
  def register_provider(module) when is_atom(module),
    do: GenServer.call(__MODULE__, {:register_provider, module})

  @doc "Verify a token using the active provider."
  @spec verify_and_resolve(String.t()) :: {:ok, Identity.t()} | {:error, term()}
  def verify_and_resolve(token),
    do: active_provider().verify_and_resolve(token)

  @doc false
  @spec reset_to_default() :: :ok
  def reset_to_default,
    do: GenServer.call(__MODULE__, :reset_to_default)

  # --- Server callbacks ---------------------------------------------------

  @impl true
  def init(_opts), do: {:ok, %{provider: @default_provider, source: :builtin}}

  @impl true
  def handle_call(:active_provider, _from, state),
    do: {:reply, state.provider, state}

  def handle_call({:register_provider, _module}, _from, %{source: :plugin} = state),
    do: {:reply, {:error, :already_registered}, state}

  def handle_call({:register_provider, module}, _from, _state),
    do: {:reply, :ok, %{provider: module, source: :plugin}}

  def handle_call(:reset_to_default, _from, _state),
    do: {:reply, :ok, %{provider: @default_provider, source: :builtin}}
end
