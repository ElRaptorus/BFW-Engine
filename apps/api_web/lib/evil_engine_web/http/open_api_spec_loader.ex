defmodule EvilEngineWeb.Http.OpenApiSpecLoader do
  @moduledoc """
  Loads the OpenAPI specification from `priv/openapi/spec.yaml` and provides
  it as a JSON-encoded binary for the spec endpoint.

  The YAML file is read and encoded once on first access, then cached in a
  persistent term for near-zero overhead on subsequent requests.

  The `servers` block is not kept in the YAML source — it is injected at
  load time from the Phoenix endpoint's HTTP port (`EVIL_HTTP_PORT`).
  """

  @spec spec_json() :: binary()
  def spec_json do
    case :persistent_term.get({__MODULE__, :spec_json}, nil) do
      nil -> load_and_cache()
      cached -> cached
    end
  end

  @doc "Force-reload the spec from disk (useful after file edits in dev)."
  @spec reload!() :: :ok
  def reload! do
    _ = load_and_cache()
    :ok
  end

  defp load_and_cache do
    json =
      spec_path()
      |> YamlElixir.read_from_file!()
      |> inject_servers()
      |> Jason.encode!()

    :persistent_term.put({__MODULE__, :spec_json}, json)
    json
  end

  defp inject_servers(spec) do
    port = runtime_http_port()

    Map.put(spec, "servers", [
      %{"url" => "http://localhost:#{port}", "description" => "Local engine"}
    ])
  end

  defp runtime_http_port do
    endpoint_config = Application.get_env(:api_web, EvilEngineWeb.Http.Endpoint, [])

    case get_in(endpoint_config, [:http, :port]) do
      nil -> 4000
      port -> port
    end
  end

  defp spec_path do
    Application.app_dir(:api_web, "priv/openapi/spec.yaml")
  end
end
