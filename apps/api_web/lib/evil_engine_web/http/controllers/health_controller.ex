defmodule EvilEngineWeb.Http.HealthController do
  @moduledoc """
  GET /health — liveness probe for Docker/k8s.

  Returns 204 No Content. Kubernetes probes check the status code only.
  For detailed pool stats, use GET /stats (auth-gated).
  """

  use Phoenix.Controller, formats: [:json]

  def index(conn, _params) do
    send_resp(conn, 204, "")
  end
end
