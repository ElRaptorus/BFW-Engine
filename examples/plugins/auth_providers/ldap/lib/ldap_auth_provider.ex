defmodule MyCompany.LdapAuthProvider do
  @moduledoc """
  Example auth provider plugin — LDAP token verification with group mapping.

  This is a **ready-to-copy starting point** for building your own auth
  provider. Replace the LDAP calls with your identity system of choice.

  ## How it works

  1. The plugin receives a raw bearer token (e.g. an opaque session token
     or a JWT issued by your corporate IdP).
  2. It verifies the token against an external system (LDAP bind in this
     example).
  3. It maps the external user record to an `%BfwEngine.Types.Identity{}`
     that the engine understands.

  ## Registration

  Register this module from your plugin's `on_load/1` callback:

      def on_load(facade) do
        facade.register_auth_provider.(MyCompany.LdapAuthProvider)
        :ok
      end

  ## Configuration

  This example reads LDAP settings from application config. In a real
  deployment you would use environment variables via `config/runtime.exs`:

      config :my_company_plugin, :ldap,
        host: System.get_env("LDAP_HOST", "ldap.corp.example.com"),
        port: String.to_integer(System.get_env("LDAP_PORT", "636")),
        base_dn: System.get_env("LDAP_BASE_DN", "dc=corp,dc=example,dc=com")
  """

  @behaviour BfwEngine.Plugin.AuthProvider

  alias BfwEngine.Types.Identity

  @doc "Verifies the bearer token with the stubbed LDAP lookup and returns a resolved engine identity."
  @impl true
  def verify_and_resolve(token) when is_binary(token) do
    case ldap_bind_and_lookup(token) do
      {:ok, ldap_user} -> {:ok, build_identity(ldap_user)}
      {:error, _reason} = error -> error
    end
  end

  # --- Private helpers (replace with your own identity system) ----------

  defp ldap_bind_and_lookup(token) do
    # In a real implementation, you would:
    #   1. Parse the token (session cookie, opaque token, etc.)
    #   2. Bind to the LDAP server with a service account
    #   3. Search for the user entry matching the token
    #   4. Return the user record or {:error, reason}
    #
    # Stubbed for illustration:
    case token do
      "valid-ldap-" <> user_id ->
        {:ok,
         %{
           uid: user_id,
           display_name: "LDAP User #{user_id}",
           groups: ["engineering", "deploy"],
           raw_attrs: %{"department" => "Engineering"}
         }}

      _ ->
        {:error, :invalid_token}
    end
  end

  defp build_identity(ldap_user) do
    %Identity{
      id: ldap_user.uid,
      roles: ldap_user.groups,
      groups: ldap_user.groups,
      claims: %{
        "sub" => ldap_user.uid,
        "name" => ldap_user.display_name,
        "groups" => ldap_user.groups,
        "ldap_attrs" => ldap_user.raw_attrs
      }
    }
  end
end
