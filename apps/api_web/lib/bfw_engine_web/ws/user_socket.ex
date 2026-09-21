defmodule BfwEngineWeb.Ws.UserSocket do
  @moduledoc """
  Phoenix Socket for engine event subscriptions.

  Clients connect with a JWT token as the `token` parameter. The
  token is validated during `connect/3`; if auth is disabled
  (`BFE_AUTH_DISABLED=true`), any connection is accepted.

  ## Topics

  - `engine:events` — all engine-level events (PI-scoped events are filtered at dispatch)
  - `process_instance:<process_instance_id>` — events for a specific process instance
  - `user_tasks:pending` — pending user-task inbox (`UserTaskCreated` / `UserTaskFinished`)
  """

  use Phoenix.Socket

  require Logger

  alias BfwEngine.Auth.ProviderRegistry

  channel "engine:*", BfwEngineWeb.Ws.EngineChannel
  channel "process_instance:*", BfwEngineWeb.Ws.EngineChannel
  channel "user_tasks:*", BfwEngineWeb.Ws.EngineChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    if auth_disabled?() do
      {:ok, assign(socket, :identity, anonymous_identity())}
    else
      case ProviderRegistry.verify_and_resolve(token) do
        {:ok, identity} ->
          {:ok, assign(socket, :identity, identity)}

        {:error, reason} ->
          Logger.info("WebSocket JWT rejected: #{reason}")
          :error
      end
    end
  end

  def connect(_params, socket, _connect_info) do
    if auth_disabled?() do
      {:ok, assign(socket, :identity, anonymous_identity())}
    else
      Logger.info("WebSocket connection refused: no token provided")
      :error
    end
  end

  @impl true
  def id(socket) do
    case socket.assigns[:identity] do
      %{id: id} when is_binary(id) -> "user_socket:#{id}"
      _ -> nil
    end
  end

  defp auth_disabled? do
    Application.get_env(:api_auth, :auth_disabled, false)
  end

  defp anonymous_identity do
    %BfwEngine.Types.Identity{id: "anonymous", roles: [], groups: [], claims: %{}}
  end
end
