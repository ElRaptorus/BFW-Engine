defmodule MyCompany.CompanyGraphAuthProvider do
  @moduledoc """
  Example auth provider plugin — CompanyGraph token verification.

  [CompanyGraph](https://companygraph.com) is an organizational identity
  API used by enterprises to manage employee records, team structures,
  and role hierarchies. This example verifies a bearer token against the
  CompanyGraph API and maps the returned user profile to the engine's
  `%Identity{}` struct.

  This is a **ready-to-copy starting point**. Replace the stubbed HTTP
  calls with real `companygraph-elixir` SDK calls or plain HTTP requests
  to your CompanyGraph tenant.

  ## How it works

  1. The plugin receives a raw bearer token (e.g. a CompanyGraph session
     token or an OAuth2 access token issued by CompanyGraph as the IdP).
  2. It calls the CompanyGraph `/me` endpoint to validate the token and
     retrieve the user profile.
  3. It maps the CompanyGraph user record (employee ID, teams, roles,
     custom attributes) to an `%EvilEngine.Types.Identity{}`, including
     engine-specific authorization claims derived from the CG roles.

  ## Stub token profiles

  The stub recognises three token prefixes, each producing a different
  engine authorization profile:

  | Token prefix | CG role | Engine claims |
  |---|---|---|
  | `cg-admin-{id}` | `admin` | Full admin: `deploy_bpmn`, `deploy_dmn`, `delete_dmn`, `abort_process_instance: "all"`, `retry_process_instance: "all"`, `zeeky_boogie_doog`, all lanes |
  | `cg-deployer-{id}` | `deployer` | `deploy_bpmn`, `deploy_dmn`, `lane:Engineering`, `abort_process_instance: "own"` |
  | `cg-viewer-{id}` | `viewer` | `lane:Operations` only (read-only lane access) |

  Any other token is rejected with `{:error, :invalid_token}`.

  ## Registration

      def on_load(facade) do
        facade.register_auth_provider.(MyCompany.CompanyGraphAuthProvider)
        :ok
      end

  ## Configuration

  In a real deployment, configure via environment variables in
  `config/runtime.exs`:

      config :my_company_plugin, :companygraph,
        api_url: System.get_env("COMPANYGRAPH_API_URL", "https://api.companygraph.com"),
        tenant_id: System.get_env("COMPANYGRAPH_TENANT_ID"),
        service_token: System.get_env("COMPANYGRAPH_SERVICE_TOKEN")
  """

  @behaviour EvilEngine.Plugin.AuthProvider

  alias EvilEngine.Types.Identity

  @doc "Verifies the bearer token with the stubbed CompanyGraph user fetch and returns a resolved engine identity."
  @impl true
  def verify_and_resolve(token) when is_binary(token) do
    case fetch_companygraph_user(token) do
      {:ok, cg_user} -> {:ok, build_identity(cg_user)}
      {:error, _reason} = error -> error
    end
  end

  # --- Private helpers (replace with real CompanyGraph API calls) -------

  defp fetch_companygraph_user(token) do
    # In a real implementation, you would:
    #   1. Call GET {api_url}/v1/me with Authorization: Bearer {token}
    #      (or use the companygraph-elixir SDK)
    #   2. Parse the JSON response into a user map
    #   3. Return {:ok, user} or {:error, reason}
    #
    # The stub maps three token prefixes to distinct role profiles so that
    # integration tests and manual testing can exercise different engine
    # authorization paths.
    case token do
      "cg-admin-" <> employee_id ->
        {:ok, cg_user_map(employee_id, "admin", ["admin"], ["platform-engineering"])}

      "cg-deployer-" <> employee_id ->
        {:ok, cg_user_map(employee_id, "deployer", ["deployer"], ["platform-engineering", "bpmn-squad"])}

      "cg-viewer-" <> employee_id ->
        {:ok, cg_user_map(employee_id, "viewer", ["viewer"], ["operations"])}

      _ ->
        {:error, :invalid_token}
    end
  end

  defp cg_user_map(employee_id, profile, roles, teams) do
    %{
      employee_id: employee_id,
      email: "#{employee_id}@corp.example.com",
      display_name: "Employee #{employee_id}",
      profile: profile,
      teams: teams,
      roles: roles,
      org_unit: "Engineering / Platform",
      custom_attrs: %{
        "cost_center" => "CC-4200",
        "location" => "Berlin"
      }
    }
  end

  defp build_identity(cg_user) do
    engine_claims = map_cg_roles_to_engine_claims(cg_user.roles)

    %Identity{
      id: cg_user.employee_id,
      roles: cg_user.roles,
      groups: cg_user.teams,
      claims:
        Map.merge(engine_claims, %{
          "sub" => cg_user.employee_id,
          "email" => cg_user.email,
          "name" => cg_user.display_name,
          "roles" => cg_user.roles,
          "groups" => cg_user.teams,
          "org_unit" => cg_user.org_unit,
          "companygraph" => cg_user.custom_attrs
        })
    }
  end

  # --- CG role → engine claim mapping -----------------------------------
  #
  # In a real deployment you would fetch boolean permissions from CompanyGraph
  # (GET /api/{tool}/permissions/{identifier}) and map them to engine claims.
  # This stub derives the mapping from the CG role name instead.
  #
  # Engine claim reference (see docs/architecture/authorization.md):
  #
  #   deploy_bpmn:              boolean   — can deploy / enable / disable BPMN processes
  #   deploy_dmn:               boolean   — can deploy DMN decisions
  #   delete_dmn:               boolean   — can delete DMN decisions
  #   lane:<Name>:              "read" | "write"  — observe or act on flow nodes on that BPMN lane
  #   abort_process_instance:   "none" | "own" | "all"
  #   retry_process_instance:   "none" | "own" | "all"
  #   zeeky_boogie_doog:        boolean   — admin override (sees everything)

  defp map_cg_roles_to_engine_claims(roles) do
    roles
    |> Enum.map(&claims_for_role/1)
    |> Enum.reduce(%{}, &merge_claims/2)
  end

  defp claims_for_role("admin") do
    %{
      "deploy_bpmn" => true,
      "deploy_dmn" => true,
      "delete_dmn" => true,
      "abort_process_instance" => "all",
      "retry_process_instance" => "all",
      "zeeky_boogie_doog" => true,
      "lane:Engineering" => "write",
      "lane:Operations" => "write",
      "lane:Management" => "write"
    }
  end

  defp claims_for_role("deployer") do
    %{
      "deploy_bpmn" => true,
      "deploy_dmn" => true,
      "abort_process_instance" => "own",
      "retry_process_instance" => "none",
      "lane:Engineering" => "write"
    }
  end

  defp claims_for_role("viewer") do
    %{
      "abort_process_instance" => "none",
      "retry_process_instance" => "none",
      "lane:Operations" => "read"
    }
  end

  defp claims_for_role(_unknown_role), do: %{}

  @scope_hierarchy %{"none" => 0, "own" => 1, "all" => 2}
  @lane_rank %{"write" => 2, "read" => 1}

  defp merge_claims(new, accumulated) do
    Map.merge(accumulated, new, fn key, existing, incoming ->
      cond do
        lane_claim?(key) ->
          if Map.get(@lane_rank, incoming, 0) > Map.get(@lane_rank, existing, 0),
            do: incoming,
            else: existing

        is_binary(existing) and Map.has_key?(@scope_hierarchy, existing) ->
          if Map.get(@scope_hierarchy, incoming, 0) > Map.get(@scope_hierarchy, existing, 0),
            do: incoming,
            else: existing

        incoming == true ->
          true

        true ->
          existing
      end
    end)
  end

  defp lane_claim?(key) when is_binary(key), do: String.starts_with?(key, "lane:")
  defp lane_claim?(_), do: false
end
