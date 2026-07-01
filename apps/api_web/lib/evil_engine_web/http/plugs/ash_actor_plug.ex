defmodule EvilEngineWeb.Http.Plugs.AshActorPlug do
  @moduledoc """
  Attaches the JWT-derived Ash actor to the Plug connection for the duration
  of each REST request.

  Reads the `%Identity{}` from `conn.assigns[:identity]` (set by
  `EvilEngine.Auth.Plug`) and calls `Ash.PlugHelpers.set_actor/2` with the
  same flat actor map produced by `AbsintheContext.prepare_actor/1`.

  In Ash 3.x the actor is stored in `conn.private[:ash][:actor]`. It is
  consumed by AshPhoenix-aware controller helpers and — after the facade
  `EvilEngine.Api` facade migration — will allow all REST calls to be policy-
  evaluated without per-call `actor:` keyword arguments.

  Note: plain `Ash.read/create/update/destroy` calls in the current Phoenix
  controllers do **not** automatically inherit this actor. They still require
  either an explicit `actor: conn` / `actor: actor` option, or they bypass
  policies via `authorize?: false`. This plug is placed in the `:authenticated`
  pipeline now so the actor is available on the conn for the facade migration.

  Must be placed **after** `EvilEngine.Auth.Plug` in the pipeline so that
  `conn.assigns[:identity]` is already populated.
  """

  @behaviour Plug

  alias Ash.PlugHelpers
  alias EvilEngineWeb.Http.Plugs.AbsintheContext

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case conn.assigns[:identity] do
      nil ->
        conn

      identity ->
        PlugHelpers.set_actor(conn, AbsintheContext.prepare_actor(identity))
    end
  end
end
