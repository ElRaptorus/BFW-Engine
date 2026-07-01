defmodule EvilEngine.Plugin.AuthProvider do
  @moduledoc """
  Behaviour for pluggable authentication providers (Phase 2 item 11).

  An auth provider receives a raw bearer token string and must return
  either a verified `%Identity{}` or an error tuple. The engine dispatches
  every authenticated request through the active provider.

  Only one auth provider can be active at a time (first-writer wins;
  duplicate registration is rejected and the offending plugin is
  quarantined). If no plugin registers a provider, the built-in JWT
  provider is used.

  ## Registration

      def on_load(facade) do
        facade.register_auth_provider.(MyPlugin.CompanyGraphAuth)
        :ok
      end

  A second plugin attempting to register another provider will receive
  `{:error, :conflict, incumbent_plugin_name}` and be quarantined.
  """

  alias EvilEngine.Types.Identity

  @type error_reason ::
          :invalid_token
          | :expired
          | :not_yet_valid
          | :no_key_configured
          | :provider_unavailable
          | term()

  @doc """
  Verify a raw bearer token and resolve it to an `%Identity{}`.

  Called on every authenticated HTTP request and WebSocket connection.
  Must be reasonably fast (< 100 ms recommended) and must not have
  side effects.
  """
  @callback verify_and_resolve(token :: String.t()) ::
              {:ok, Identity.t()} | {:error, error_reason()}
end
