defmodule EvilEngineWeb.Http.Plugs.AbsintheContext do
  @moduledoc """
  Bridges the JWT-derived `%Identity{}` into the Absinthe/Ash context
  so that Ash policies can enforce visibility rules on GraphQL queries.

  Extracts `lane:*` claim keys (`\"read\"` or `\"write\"`) into
  `accessible_lanes`, `\"write\"` into `writable_lanes`, and sets
  `observe_all` plus `zeeky_boogie_doog` for policy checks.
  """

  alias EvilEngine.Api.Validation

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case conn.assigns[:identity] do
      nil ->
        conn

      identity ->
        actor = prepare_actor(identity)
        Absinthe.Plug.put_options(conn, context: %{actor: actor})
    end
  end

  @doc """
  Build an Ash-compatible actor map from an `%Identity{}`.

  The map contains flat keys consumable by `^actor(:key)` expressions
  in Ash policy filters. All boolean claim fields are coerced to `true`
  or `false` so policies can use `^actor(:key) == true` safely.
  """
  def prepare_actor(identity) do
    %{
      id: identity.id,
      accessible_lanes: Validation.accessible_lanes(identity),
      writable_lanes: Validation.writable_lanes(identity),
      observe_all: Validation.observe_all?(identity),
      zeeky_boogie_doog: identity.claims["zeeky_boogie_doog"] == true,
      deploy_bpmn: identity.claims["deploy_bpmn"] == true,
      delete_bpmn: identity.claims["delete_bpmn"] == true,
      deploy_dmn: identity.claims["deploy_dmn"] == true,
      delete_dmn: identity.claims["delete_dmn"] == true,
      trigger_message: identity.claims["trigger_message"],
      trigger_signal: identity.claims["trigger_signal"],
      abort_process_instance: identity.claims["abort_process_instance"],
      retry_process_instance: identity.claims["retry_process_instance"],
      delete_process_instance: identity.claims["delete_process_instance"],
      purge_audit_data: identity.claims["purge_audit_data"] == true
    }
  end
end
