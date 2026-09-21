defmodule MyCompany.LdapPlugin do
  @moduledoc """
  Example plugin that registers an LDAP-based auth provider.

  Copy this module and `LdapAuthProvider` into your own plugin project.
  See the engine's Plugin documentation for the full lifecycle.
  """

  @behaviour BfwEngine.Plugin

  @doc "Registers the LDAP auth provider with the engine facade during plugin initialization."
  @impl true
  def on_load(facade) do
    facade.register_auth_provider.(MyCompany.LdapAuthProvider)
    :ok
  end

  @doc "Called after all plugins are loaded; no additional setup is required for this example."
  @impl true
  def on_ready(_facade), do: :ok
end
