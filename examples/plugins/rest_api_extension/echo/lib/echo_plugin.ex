defmodule Examples.Plugins.RestApiExtension.EchoPlug do
  @moduledoc """
  Minimal RestApiExtension Plug: `GET <prefix>/ping` returns JSON `{pong: true}`.
  """

  @behaviour Plug
  @behaviour BfwEngine.Plugin.RestApiExtension

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{path_info: ["ping"]} = conn, _opts) do
    identity_id =
      case conn.assigns[:identity] do
        %{id: id} -> id
        _ -> nil
      end

    body = Jason.encode!(%{pong: true, identityId: identity_id})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  def call(conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "not_found"}))
  end
end

defmodule Examples.Plugins.RestApiExtension.EchoPlugin do
  @moduledoc """
  Registers the echo RestApiExtension under `/echo-ext`.
  """

  @behaviour BfwEngine.Plugin

  @impl true
  def on_load(engine_facade) do
    case engine_facade.register_rest_api_extension.(
           "/echo-ext",
           Examples.Plugins.RestApiExtension.EchoPlug
         ) do
      :ok -> :ok
      error -> {:error, {:register_rest_api_extension_failed, error}}
    end
  end

  @impl true
  def on_ready(_engine_facade), do: :ok
end
