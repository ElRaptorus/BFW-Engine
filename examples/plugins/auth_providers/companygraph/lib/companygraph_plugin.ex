defmodule MyCompany.CompanyGraphPlugin do
  @moduledoc """
  Example plugin that registers a CompanyGraph-based auth provider and
  seeds a permission catalog with CompanyGraph at startup.

  Copy this module and `CompanyGraphAuthProvider` into your own plugin
  project. See the engine's Plugin documentation for the full lifecycle.

  ## Lifecycle

  | Callback | What happens |
  |----------|---|
  | `on_load/1` | Registers `CompanyGraphAuthProvider` as the engine's auth provider. Fails fast if registration is rejected (another provider already registered). |
  | `on_ready/1` | Seeds the permission catalog with CompanyGraph (stubbed). In production, this would POST the tool name and permission list to the CG API. |

  ## Permission seeding

  Real CompanyGraph integrations register two things at startup:

  1. **Tool identity** — `POST /api/tools` with the tool name (idempotent,
     HTTP 200 or 409).
  2. **Permission catalog** — `POST /api/tools/{tool}/berechtigungen` with
     the list of boolean permission names the application requires.

  This example stubs both calls and defines two simple example permissions
  (`can_deploy_processes` and `can_view_instances`) to illustrate the
  pattern without introducing external dependencies.
  """

  @behaviour EvilEngine.Plugin

  require Logger

  @tool_name "my-workflow-app"

  @permissions [
    "can_deploy_processes",
    "can_view_instances"
  ]

  @doc "Returns the tool name registered with CompanyGraph."
  @spec tool_name() :: String.t()
  def tool_name, do: @tool_name

  @doc "Returns the permission catalog seeded with CompanyGraph."
  @spec permissions() :: [String.t()]
  def permissions, do: @permissions

  @impl true
  def on_load(facade) do
    case facade.register_auth_provider.(MyCompany.CompanyGraphAuthProvider) do
      :ok ->
        Logger.info("companygraph_plugin: auth provider registered")
        :ok

      {:error, :conflict, incumbent} ->
        Logger.error(
          "companygraph_plugin: auth provider rejected — " <>
            "#{incumbent} is already registered"
        )

        {:error, :auth_provider_conflict}

      {:error, reason, detail} ->
        Logger.error(
          "companygraph_plugin: auth provider registration failed — " <>
            "#{inspect(reason)}: #{inspect(detail)}"
        )

        {:error, reason}
    end
  end

  @impl true
  def on_ready(_facade) do
    register_tool_with_companygraph()
    register_permissions_with_companygraph()
    :ok
  end

  # --- CG registration stubs (replace with real HTTP calls) -------------
  #
  # In a real deployment these functions would use an HTTP client (e.g. Req)
  # with an OAuth2 service token to call the CompanyGraph API:
  #
  #   POST {cg_base_url}/api/tools
  #     body: %{"tool" => @tool_name}
  #     success: 200 or 409 (already registered)
  #
  #   POST {cg_base_url}/api/tools/{@tool_name}/berechtigungen
  #     body: %{"tool" => @tool_name, "berechtigungen" => @permissions}
  #     success: 200

  defp register_tool_with_companygraph do
    Logger.info("companygraph_plugin: registering tool '#{@tool_name}' with CompanyGraph (stubbed)")
    :ok
  end

  defp register_permissions_with_companygraph do
    Logger.info(
      "companygraph_plugin: seeding #{length(@permissions)} permission(s) " <>
        "for '#{@tool_name}' with CompanyGraph (stubbed): #{inspect(@permissions)}"
    )

    :ok
  end
end
