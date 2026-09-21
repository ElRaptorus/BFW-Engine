defmodule BfwEngineWeb.Http.OpenApiController do
  @moduledoc "Serves the OpenAPI 3.0 spec as JSON from `priv/openapi/spec.yaml`."

  use Phoenix.Controller, formats: [:json]

  alias BfwEngineWeb.Http.OpenApiSpecLoader

  def spec(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, OpenApiSpecLoader.spec_json())
  end
end
