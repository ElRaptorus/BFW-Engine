defmodule BfwEngineWeb.Http.PluginExtensionController do
  @moduledoc """
  Dispatches unmatched HTTP paths to a plugin RestApiExtension.

  Lookup happens before authentication so unknown paths stay HTTP 404.
  When a plugin prefix matches, JWT is resolved and Identity is assigned;
  engine claim policy is **not** applied — plugins enforce their own
  authorization from `conn.assigns.identity`.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  import BfwEngineWeb.Http.ErrorResponse

  alias BfwEngine.Auth.Plug, as: AuthPlug
  alias BfwEngine.Plugins.Registry
  alias BfwEngineWeb.Http.Plugs.AshActorPlug

  @doc """
  Look up a RestApiExtension by longest matching prefix and invoke its Plug.
  """
  @spec dispatch(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def dispatch(conn, _params) do
    request_path = "/" <> Enum.join(conn.path_info, "/")

    case Registry.lookup_rest_api_extension(request_path) do
      {:ok, %{prefix: prefix, module: handler_module}} when is_atom(handler_module) ->
        conn
        |> authenticate_plugin_request()
        |> maybe_invoke_extension(prefix, handler_module)

      _other ->
        render_error(conn, 404, "not_found", "Not found")
    end
  end

  defp authenticate_plugin_request(conn) do
    conn
    |> AuthPlug.call(AuthPlug.init([]))
    |> assign_ash_actor_if_authenticated()
  end

  defp assign_ash_actor_if_authenticated(%{halted: true} = conn), do: conn

  defp assign_ash_actor_if_authenticated(conn) do
    AshActorPlug.call(conn, AshActorPlug.init([]))
  end

  defp maybe_invoke_extension(%{halted: true} = conn, _prefix, _handler_module), do: conn

  defp maybe_invoke_extension(conn, prefix, handler_module) do
    conn
    |> strip_matched_prefix(prefix)
    |> invoke_extension_handler(handler_module)
  end

  defp strip_matched_prefix(conn, prefix) do
    prefix_segments =
      prefix
      |> String.trim("/")
      |> String.split("/", trim: true)

    remaining_path_info = Enum.drop(conn.path_info, length(prefix_segments))

    %{
      conn
      | script_name: conn.script_name ++ prefix_segments,
        path_info: remaining_path_info
    }
  end

  defp invoke_extension_handler(conn, handler_module) do
    router_module = extension_router_module(handler_module)

    opts =
      if function_exported?(router_module, :init, 1) do
        router_module.init([])
      else
        []
      end

    router_module.call(conn, opts)
  rescue
    error ->
      Logger.error(
        "plugin RestApiExtension handler crashed: #{Exception.format(:error, error, __STACKTRACE__)}"
      )

      render_error(
        conn,
        500,
        "internal_error",
        "Plugin REST extension failed"
      )
  end

  defp extension_router_module(handler_module) do
    if function_exported?(handler_module, :router_module, 0) do
      handler_module.router_module()
    else
      handler_module
    end
  end
end
